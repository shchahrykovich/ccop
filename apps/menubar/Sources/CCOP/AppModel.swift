import AppKit
import CCOPKit
import Observation

/// The app's state. Loads the sessions from the CLI: every 30 s while the
/// popover is open, every 2 min while it is closed (for the menu bar number).
@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [Session] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    var query = ""
    /// Saved on each change, so a new launch shows the same period.
    var period = Period.load() {
        didSet { period.save() }
    }
    /// The project folder the list shows (alone or with its subfolders); nil for all folders.
    /// Saved on each change, so a new launch shows the same folder.
    var folder = FolderScope.load() {
        didSet { FolderScope.save(folder) }
    }
    var selectedID: String?
    var now = Date()
    var popoverOpen = false {
        didSet { if popoverOpen, !oldValue, !paused { refresh() } }
    }
    /// The main window is shown: refresh as often as with the popover open.
    var windowOpen = false {
        didSet { if windowOpen, !oldValue, !paused { refresh() } }
    }
    /// The session and tab shown in the main window (apart from the popover's).
    var windowSelectedID: String? {
        didSet { if windowSelectedID != oldValue { chatLane = "main" } }
    }
    /// The lane the Chat tab shows: "main" or a subagent's id. Anatomy sets it
    /// to open one agent's chat.
    var chatLane = "main"
    /// No automatic updates (sessions, times, limits) while the user looks at
    /// the data; Refresh still reads once. Not saved: a new launch updates.
    var paused = false
    var windowTab: DetailTab = .overview
    /// Day sections the user closed ("Today", "Yesterday", "Friday 30 October").
    var collapsedDays: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedDays") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedDays).sorted(), forKey: "collapsedDays") }
    }
    /// The subscription plan (tier, reset, weekly limit); saved on each change.
    var plan = PlanSettings.load() {
        didSet { plan.save() }
    }
    /// Tokens and cost by hour for the last 3 weeks.
    private(set) var usageReport: UsageReport?
    /// The last read of `claude -p /usage`; read at launch, then every hour.
    private(set) var limits: UsageLimits? = UsageLimits.load()
    private(set) var limitsReading = false
    private(set) var limitsError: String?
    /// A new read waits for a fresh usage report before it calibrates.
    @ObservationIgnored private var pendingCalibration = false
    @ObservationIgnored private var lastLimitsTry = Date.distantPast
    static let limitsInterval: TimeInterval = 3600
    /// Set by StatusItemController: opens the plan settings window.
    @ObservationIgnored var openPlanSettings: (() -> Void)?
    /// Anatomies loaded, by session id, and the ones loading now.
    private(set) var anatomies: [String: AnatomyState] = [:]
    /// Set by StatusItemController: opens the main window at a session and tab.
    @ObservationIgnored var openWindow: ((String?, DetailTab?) -> Void)?

    @ObservationIgnored private let source: SessionSource?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastLoad = Date.distantPast

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(Updater.Release)
        case downloading(Updater.Release)
        case failed(String)
    }

    private(set) var update: UpdateState = .idle
    /// Check GitHub for a new version every 6 hours (on by default).
    var autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }
    /// Read `claude -p /usage` at launch, then every hour (on by default).
    var autoReadLimits = UserDefaults.standard.object(forKey: "autoReadLimits") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReadLimits, forKey: "autoReadLimits") }
    }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    /// The Team ID this app is signed with; nil for a local (ad-hoc) build.
    @ObservationIgnored private let teamID = Updater.teamIdentifier(of: Bundle.main.bundleURL)
    /// A local build ("CCOP Dev"): its menu bar battery is dark, so it is not taken for the release.
    var isLocalBuild: Bool { Updater.isLocalBuild(teamID: teamID) }
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init(source: SessionSource? = CLISessionSource.locate().map { CLISessionSource(cli: $0) }) {
        self.source = source
    }

    func start() {
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if self?.autoUpdate == true { await self?.checkForUpdates(manual: false) }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
        refresh()
        if autoReadLimits { readLimits() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Paused: the shown data and its "N min ago" stay as they are.
                guard let self, !self.paused else { return }
                self.now = Date()
                let every: TimeInterval = self.popoverOpen || self.windowOpen ? 30 : 120
                if Date().timeIntervalSince(self.lastLoad) >= every { self.refresh() }
                if self.autoReadLimits, Date().timeIntervalSince(self.lastLimitsTry) >= Self.limitsInterval { self.readLimits() }
            }
        }
    }

    /// Runs `claude -p /usage` and keeps what it shows. The weekly reset and
    /// limit follow from it once a fresh usage report is in.
    func readLimits() {
        guard !limitsReading else { return }
        limitsReading = true
        lastLimitsTry = Date()
        Task.detached(priority: .utility) {
            let result = Result { try LimitsReader.read() }
            await MainActor.run {
                self.limitsReading = false
                switch result {
                case let .success(l):
                    self.limits = l
                    l.save()
                    self.limitsError = nil
                    self.pendingCalibration = true
                    if self.loading { return }
                    self.refresh()
                case let .failure(e):
                    self.limitsError = e.localizedDescription
                }
            }
        }
    }

    private func applyLimitsIfReady() {
        guard pendingCalibration, let limits, let usageReport, usageReport.generatedAt >= limits.readAt.addingTimeInterval(-60) else { return }
        pendingCalibration = false
        plan = Plan.applying(limits, to: plan, report: usageReport).settings
    }

    func refresh() {
        guard !loading else { return }
        guard let source else {
            error = SessionSourceError.cliNotFound.localizedDescription
            return
        }
        loading = true
        lastLoad = Date()
        Task.detached(priority: .utility) {
            let result = Result { try source.load() }
            // Runs after the sessions, so it finds the index up to date.
            let usage = Result { try source.usage(days: 21) }
            await MainActor.run {
                self.loading = false
                self.now = Date()
                switch result {
                case let .success(list):
                    self.sessions = list
                    self.error = nil
                    self.loadedAt = Date()
                case let .failure(e):
                    self.error = e.localizedDescription
                }
                switch usage {
                case let .success(report):
                    self.usageReport = report
                    self.applyLimitsIfReady()
                case let .failure(e): self.error = self.error ?? e.localizedDescription
                }
                // A read of /usage that ended while this refresh ran needs a newer report.
                if self.pendingCalibration, case .success = usage { self.refresh() }
            }
        }
    }

    var visible: [Session] {
        SessionList.filter(sessions, query: query, period: period, folder: folder, now: now)
    }

    /// The folder menu: folders with sessions in the period, and the chosen one.
    var folderChoices: [FolderChoice] {
        SessionList.folders(sessions, period: period, keeping: folder?.path, now: now)
    }

    var selected: Session? {
        selectedID.flatMap { id in sessions.first { $0.id == id } }
    }

    var activeCount: Int { sessions.filter(\.active).count }

    var windowSelected: Session? {
        // `--window <id-prefix>` gives a prefix.
        windowSelectedID.flatMap { id in sessions.first { $0.id == id } ?? sessions.first { $0.id.hasPrefix(id) } }
    }

    func toggleDay(_ title: String) {
        if collapsedDays.contains(title) { collapsedDays.remove(title) } else { collapsedDays.insert(title) }
    }

    /// Loads a session's anatomy; again when `reload` or when the session
    /// changed since it was loaded.
    func loadAnatomy(_ s: Session, reload: Bool = false) {
        if case .loading = anatomies[s.id] { return }
        if !reload, case let .loaded(_, at) = anatomies[s.id], at >= s.modifiedAt { return }
        guard let source else { anatomies[s.id] = .failed(SessionSourceError.cliNotFound.localizedDescription); return }
        anatomies[s.id] = .loading
        let id = s.id
        Task.detached(priority: .userInitiated) {
            let result = Result { try source.anatomy(id) }
            await MainActor.run {
                switch result {
                case let .success(a): self.anatomies[id] = .loaded(a, Date())
                case let .failure(e): self.anatomies[id] = .failed(e.localizedDescription)
                }
            }
        }
    }

    /// The full texts of one lane, read on demand (not cached: a running session grows).
    func chat(_ sessionID: String, lane: String) async -> Result<LaneChat, Error> {
        guard let source else { return .failure(SessionSourceError.cliNotFound) }
        return await Task.detached(priority: .userInitiated) { Result { try source.chat(sessionID, lane: lane) } }.value
    }

    /// One tool call in full.
    func call(_ sessionID: String, toolUseID: String) async -> Result<ToolCall, Error> {
        guard let source else { return .failure(SessionSourceError.cliNotFound) }
        return await Task.detached(priority: .userInitiated) { Result { try source.call(sessionID, toolUseID: toolUseID) } }.value
    }

    var todayTokens: UInt64 { SessionList.todayTotal(sessions, now: now) }

    /// This week against the weekly limit; nil before a reset time is set.
    var weekStatus: WeekStatus? {
        usageReport.flatMap { Plan.status(settings: plan, report: $0, now: now) }
    }

    /// This week against the week before; nil before a reset time is set.
    var weekComparison: (status: WeekStatus, comparison: WeekComparison)? {
        guard let status = weekStatus, let usageReport else { return nil }
        return (status, Plan.comparison(status, report: usageReport, now: now))
    }

    /// Sets the weekly limit from the percent /usage shows now. Returns false
    /// when it cannot (no reset time, no usage yet, or a percent not above 0).
    @discardableResult
    func calibrate(usedPercent: Double) -> Bool {
        guard let status = weekStatus, status.usedMicros > 0,
              let budget = Plan.calibrate(usedPercent: usedPercent, usedMicros: status.usedMicros) else { return false }
        plan.weeklyBudgetMicros = budget
        plan.calibratedAt = Date()
        return true
    }

    // MARK: Updates

    /// A manual check reports every result; an automatic one only an update.
    func checkForUpdates(manual: Bool) async {
        if case .downloading = update { return }
        if let reason = Updater.disabledReason(teamID: teamID) {
            update = manual ? .failed(reason) : .idle
            return
        }
        update = .checking
        do {
            let release = try await Updater.latest(currentVersion: version)
            if Updater.isNewer(release.version, than: version) {
                update = .available(release)
            } else {
                update = manual ? .upToDate : .idle
            }
        } catch {
            update = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Downloads the release, checks it with Gatekeeper, starts the install
    /// script and quits. The script opens the new version.
    func installUpdate(_ release: Updater.Release) async {
        guard let teamID, Updater.disabledReason(teamID: teamID) == nil else {
            update = .failed(Updater.disabledReason(teamID: teamID) ?? "No Team ID.")
            return
        }
        if let obstacle = Updater.obstacle(appURL: Bundle.main.bundleURL) {
            update = .failed(obstacle)
            return
        }
        update = .downloading(release)
        do {
            let dmg = try await Updater.download(release)
            try await Task.detached { try Updater.checkImage(dmg) }.value
            try Updater.startInstall(dmg: dmg, app: Bundle.main.bundleURL, team: teamID)
            try? await Task.sleep(for: .milliseconds(600))
            NSApp.terminate(nil)
        } catch {
            update = .failed(error.localizedDescription)
        }
    }

    func dismissUpdateMessage() {
        if case .downloading = update { return }
        update = .idle
    }

    // MARK: Actions

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyResumeCommand(_ s: Session) {
        copy(Resume.command(s))
    }

    /// Opens Terminal with `claude --resume` in the session's folder.
    func resumeInTerminal(_ s: Session) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccop-resume-\(s.id).command")
        do {
            try Resume.script(s).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            self.error = "Could not open Terminal: \(error.localizedDescription)"
        }
    }

    func revealTranscript(_ s: Session) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.transcript)])
    }

    func openProjectFolder(_ s: Session) {
        let url = URL(fileURLWithPath: s.projectDir)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            error = "The folder \(s.projectDir) does not exist any more."
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case overview, spend, chat, anatomy, context
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .spend: "Spend"
        case .chat: "Chat"
        case .anatomy: "Anatomy"
        case .context: "Context"
        }
    }
}

enum AnatomyState {
    case loading
    /// The anatomy, and when it was loaded.
    case loaded(Anatomy, Date)
    case failed(String)
}
