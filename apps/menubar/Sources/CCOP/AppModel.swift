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
    var period: Period = .week
    /// The project folder the list shows; nil for all folders.
    var folder: String?
    var selectedID: String?
    var now = Date()
    var popoverOpen = false {
        didSet { if popoverOpen, !oldValue { refresh() } }
    }
    /// The main window is shown: refresh as often as with the popover open.
    var windowOpen = false {
        didSet { if windowOpen, !oldValue { refresh() } }
    }
    /// The session and tab shown in the main window (apart from the popover's).
    var windowSelectedID: String?
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
    /// Set by StatusItemController: opens the plan settings window.
    @ObservationIgnored var openPlanSettings: (() -> Void)?
    /// Anatomies loaded, by session id, and the ones loading now.
    private(set) var anatomies: [String: AnatomyState] = [:]
    /// Set by StatusItemController: opens the main window at a session and tab.
    @ObservationIgnored var openWindow: ((String?, DetailTab?) -> Void)?

    @ObservationIgnored private let source: SessionSource?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastLoad = Date.distantPast

    init(source: SessionSource? = CLISessionSource.locate().map { CLISessionSource(cli: $0) }) {
        self.source = source
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                let every: TimeInterval = self.popoverOpen || self.windowOpen ? 30 : 120
                if Date().timeIntervalSince(self.lastLoad) >= every { self.refresh() }
            }
        }
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
                case let .success(report): self.usageReport = report
                case let .failure(e): self.error = self.error ?? e.localizedDescription
                }
            }
        }
    }

    var visible: [Session] {
        SessionList.filter(sessions, query: query, period: period, folder: folder, now: now)
    }

    /// The folder menu: folders with sessions in the period, and the chosen one.
    var folderChoices: [FolderChoice] {
        SessionList.folders(sessions, period: period, keeping: folder, now: now)
    }

    var selected: Session? {
        selectedID.flatMap { id in sessions.first { $0.id == id } }
    }

    var activeCount: Int { sessions.filter(\.active).count }

    var windowSelected: Session? {
        windowSelectedID.flatMap { id in sessions.first { $0.id == id } }
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
