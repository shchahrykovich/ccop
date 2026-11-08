import CCOPKit
import SwiftUI

/// One session in the main window: the Overview tab (board "Window · Overview").
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var wide = true
    @State private var fourCards = true

    var body: some View { overview }

    private var anatomy: Anatomy? {
        // The anatomy of the tab: new data does not change it.
        if case let .loaded(a, _) = model.windowAnatomy { return a }
        return nil
    }

    private var overview: some View {
        let s = session
        let a = anatomy
        return PageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Four cards in a row fill a wide page; narrower, they wrap at 180 each.
                LazyVGrid(columns: fourCards ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
                    : [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    StatCard(label: "API-equivalent cost", value: Format.dollars(s.costMicros), detail: limitShare(s), big: true)
                        .help(limitShare(s) == nil ? "" : Plan.limitShareHelp)
                    StatCard(label: "Tokens", value: Format.tokens(s.usage.total),
                             detail: "\(Format.percent(s.usage.cacheHitRatio)) of input from cache", big: true)
                    StatCard(label: "Model calls", value: "\(s.usage.requests)", detail: callsLine(s), big: true)
                    StatCard(label: "Average context", value: a?.contextSize.map { Format.tokens($0.average) } ?? "–",
                             detail: a.flatMap(contextLine), big: true)
                }
                .onGeometryChange(for: Bool.self) { $0.size.width >= 4 * 180 + 3 * 12 } action: { fourCards = $0 }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tokens by kind").font(.ui(13, .semibold))
                    UsageBar(usage: s.usage, legend: false, height: 8)
                    UsageTable(session: s, anatomy: a, compact: false)
                }
                if let a, a.compactions > 0 { CompactionTable(anatomy: a) }
                if let a, a.lanes.count > 1 { SubagentTree(anatomy: a) }
                // Two columns of at least 300 with a gap of 28, else one.
                let columns = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
                columns {
                    facts(s)
                    prompts(s, a)
                }
                .onGeometryChange(for: Bool.self) { $0.size.width >= 628 } action: { wide = $0 }
                HStack(spacing: 8) {
                    Button { model.resumeInTerminal(s) } label: { IconLabel(title: "Resume in Terminal", symbol: "terminal", iconSize: 14) }
                        .buttonStyle(DesignButtonStyle(kind: .primary, height: 30, radius: 7, padding: 14))
                    Button("Copy resume command") { model.copyResumeCommand(s) }
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 30, radius: 7, padding: 12))
                        .help(Resume.command(s))
                    Button("Copy for Agent") { model.copyForAgent(s) }
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 30, radius: 7, padding: 12))
                        .help("Copy the instructions for an agent and this session's id. Paste them into an agent and add your question.")
                    Button("Show transcript") { model.revealTranscript(s) }
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 30, radius: 7, padding: 12))
                    Button("Open folder") { model.openProjectFolder(s) }
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 30, radius: 7, padding: 12))
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Facts").font(.ui(13, .semibold)).padding(.bottom, 4)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow { label("Project", 24); CopyableValue(text: Theme.shortPath(s.projectDir), help: "Copy the project path", size: 12, rowHeight: 24) }
                if let b = s.gitBranch {
                    GridRow { label("Branch", 24); CopyableValue(text: b, help: "Copy the branch name", size: 12, rowHeight: 24) }
                }
                if let t = s.startedAt { GridRow { label("Started", 24); value(Self.dateTime(t), 24) } }
                GridRow {
                    label("Last activity", 24)
                    value("\(Self.dateTime(s.lastActivity)) (\(Format.ago(s.lastActivity, now: model.now)))", 24)
                }
                GridRow { label("Prompts", 24); value(promptsLine(s), 24) }
                GridRow { label("Transcript", 24); value(transcriptLine(s), 24) }
                GridRow { label("Session id", 24); CopyableValue(text: s.id, help: "Copy the session id", size: 12, rowHeight: 24) }
                if let next = s.continuedIn {
                    GridRow {
                        label("Continued in", 24)
                        Button(String(next.prefix(8))) { model.windowSelectedID = next }.buttonStyle(.link)
                    }
                }
            }
            .font(.ui(12.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prompts(_ s: Session, _ a: Anatomy?) -> some View {
        let times = a?.promptTimes
        return VStack(alignment: .leading, spacing: 12) {
            Text("Prompts").font(.ui(13, .semibold))
            if let p = s.firstPrompt { promptCard("First", p, times?.first ?? s.startedAt) }
            if let p = s.lastPrompt, p != s.firstPrompt { promptCard("Last", p, times?.last) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promptCard(_ title: String, _ text: String, _ at: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([title, at.map { $0.formatted(date: .omitted, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(11)).foregroundStyle(Theme.text3)
            Text(text).lineSpacing(3).textSelection(.enabled).lineLimit(8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Parts

    private func label(_ text: String, _ height: CGFloat) -> some View {
        Text(text).foregroundStyle(Theme.text3).frame(minHeight: height).gridColumnAlignment(.leading)
    }

    private func value(_ text: String, _ height: CGFloat) -> some View {
        Text(text).frame(minHeight: height)
    }

    /// `3 Nov 2026, 09:12`
    static func dateTime(_ d: Date) -> String {
        dateTimeFormat.string(from: d)
    }

    private static let dateTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMMyyyy", options: 0, locale: .current).map { $0 + ", " } ?? ""
        f.dateFormat += DateFormatter.dateFormat(fromTemplate: "jjmm", options: 0, locale: .current) ?? "HH:mm"
        return f
    }()

    private func promptsLine(_ s: Session) -> String {
        "\(s.prompts) typed, \(s.usage.requests) model calls, \(s.subagents) subagent\(s.subagents == 1 ? "" : "s")"
    }

    private func transcriptLine(_ s: Session) -> String {
        [Format.bytes(s.sizeBytes), s.version.map { "Claude Code \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func callsLine(_ s: Session) -> String {
        let sub = s.subagentUsage.requests
        guard sub > 0 else { return "all in the main session" }
        return "\(s.usage.requests - min(sub, s.usage.requests)) main · \(sub) in \(s.subagents) subagent\(s.subagents == 1 ? "" : "s")"
    }

    private func contextLine(_ a: Anatomy) -> String? {
        guard let c = a.contextSize else { return nil }
        return "max \(Format.tokens(c.max)) · \(plural(a.compactions, "compaction"))"
    }

    private func limitShare(_ s: Session) -> String? {
        Plan.limitShare(costMicros: s.costMicros, weeklyBudgetMicros: model.plan.weeklyBudgetMicros)
    }
}

/// Tokens by kind for the whole session and each model; in the window also
/// the subagents and the calls. The cost of a model or the subagents comes
/// from the anatomy, so it is empty until that is read.
struct UsageTable: View {
    let session: Session
    var anatomy: Anatomy?
    var compact = false

    private struct Row: Identifiable {
        let id: String
        let name: String
        var note: String?
        let usage: TokenUsage
        let cost: UInt64?
        var bold = false
        var mono = false
    }

    private var rows: [Row] {
        let costs = anatomy?.costByModel
        var out = [Row(id: "all", name: "All", usage: session.usage, cost: session.costMicros, bold: true)]
        if !compact, session.subagents > 0 {
            out.append(Row(id: "sub", name: "Subagents", usage: session.subagentUsage, cost: anatomy?.subagentCostMicros))
        }
        for m in session.models {
            var note: String?
            if compact, let a = anatomy {
                let mainModel = a.lane("main")?.model
                let n = a.lanes.filter { $0.id != "main" && $0.model == m.model }.count
                if n > 0, m.model != mainModel { note = "\(n) subagent\(n == 1 ? "" : "s")" }
            }
            out.append(Row(id: m.model, name: compact ? m.model.replacingOccurrences(of: "claude-", with: "") : m.model,
                           note: note, usage: m.usage, cost: costs?[m.model], mono: true))
        }
        return out
    }

    var body: some View {
        let size: CGFloat = compact ? 12 : 12.5
        let pad: CGFloat = compact ? 4 : 7
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text(compact ? "Model" : "Who").frame(maxWidth: .infinity, alignment: .leading)
                head("Input", Theme.input)
                head("Cache write", Theme.cacheWrite)
                head("Cache read", Theme.cacheRead)
                head("Output", Theme.output)
                if !compact { Text("Calls") }
                Text("Cost")
            }
            .font(.ui(11, .medium))
            .foregroundStyle(Theme.text3)
            .padding(.vertical, compact ? 3 : 6)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                Rectangle().fill(i == 0 ? Theme.line : Theme.line2).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    HStack(spacing: 0) {
                        Text(row.name).font(row.mono ? .mono(compact ? 11.5 : 12) : .ui(size, row.bold ? .semibold : .regular))
                        if let note = row.note { Text(" · \(note)").font(.ui(size)).foregroundStyle(Theme.text3) }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.tokens(row.usage.inputTokens))
                    Text(Format.tokens(row.usage.cacheWriteTokens))
                    Text(Format.tokens(row.usage.cacheReadTokens))
                    Text(Format.tokens(row.usage.outputTokens))
                    if !compact { Text("\(row.usage.requests)") }
                    Text(row.cost.map(Format.dollars) ?? "").fontWeight(row.bold ? .semibold : .regular)
                }
                .font(.ui(size))
                .monospacedDigit()
                .padding(.vertical, pad)
            }
        }
    }

    private func head(_ title: String, _ color: Color) -> some View {
        HStack(spacing: compact ? 4 : 5) {
            Circle().fill(color).frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            Text(title)
        }
    }
}

/// The subagents as a tree: each under the agent that started it, with what
/// it did and cost. A quick look at what the session is doing; the button
/// opens one agent's chat.
struct SubagentTree: View {
    @Environment(AppModel.self) private var model
    @State private var sort = TableSort<Column>()
    let anatomy: Anatomy
    @State private var showAll = false
    @State private var shownCall: CallRef?

    private static let firstRows = 12

    /// The columns Day limit and Week limit show only with a limit.
    private var hasLimit: Bool {
        Plan.limitParts(costMicros: 0, weeklyBudgetMicros: model.plan.weeklyBudgetMicros) != nil
    }

    var body: some View {
        let tree = anatomy.lanesInTreeOrder.filter { $0.id != "main" }
        let lanes = sort.sorted(tree, ascending: Self.ascending)
        let shown = showAll ? lanes : Array(lanes.prefix(Self.firstRows))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Subagents").font(.ui(13, .semibold))
                Text(([String(lanes.count), Format.dollars(anatomy.subagentCostMicros)]
                        + [Plan.limitShare(costMicros: anatomy.subagentCostMicros, weeklyBudgetMicros: model.plan.weeklyBudgetMicros)].compactMap { $0 })
                        .joined(separator: " · "))
                    .font(.ui(11)).foregroundStyle(Theme.text3).monospacedDigit()
                    .help(Plan.limitShareHelp)
            }
            let lines = shown.map(line)
            let widths = Widths(lines, hasLimit: hasLimit)
            VStack(alignment: .leading, spacing: 0) {
                columns(widths) {
                    SortTitle(title: "Agent", column: Column.agent, sort: $sort, alignment: .leading)
                } cells: {
                    SortTitle(title: "Model", column: Column.model, sort: $sort, alignment: .leading)
                        .frame(width: widths.model, alignment: .leading)
                    SortTitle(title: "Start", column: Column.start, sort: $sort).frame(width: widths.start, alignment: .trailing)
                    SortTitle(title: "Time", column: Column.time, sort: $sort).frame(width: widths.time, alignment: .trailing)
                    SortTitle(title: "Tokens", column: Column.tokens, sort: $sort).frame(width: widths.tokens, alignment: .trailing)
                    SortTitle(title: "Tools", column: Column.tools, sort: $sort).frame(width: widths.tools, alignment: .trailing)
                    SortTitle(title: "Compactions", column: Column.compactions, sort: $sort).frame(width: widths.compactions, alignment: .trailing)
                    SortTitle(title: "Cost", column: Column.cost, sort: $sort).frame(width: widths.cost, alignment: .trailing)
                    if hasLimit {
                        SortTitle(title: "Day limit", column: Column.day, sort: $sort, help: Plan.limitShareHelp)
                            .frame(width: widths.day, alignment: .trailing)
                        SortTitle(title: "Week limit", column: Column.week, sort: $sort, help: Plan.limitShareHelp)
                            .frame(width: widths.week, alignment: .trailing)
                    }
                    Color.clear.frame(width: Self.buttonSize, height: 1)
                }
                .font(.ui(11, .medium))
                .foregroundStyle(Theme.text3)
                .padding(.vertical, 6)
                ForEach(lines, id: \.lane.id) { line in
                    Rectangle().fill(Theme.line2).frame(height: 1)
                    row(line, widths)
                }
            }
            .font(.ui(12.5))
            if lanes.count > Self.firstRows {
                Button(showAll ? "Show fewer" : "Show all \(lanes.count)") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(Theme.accent)
            }
        }
        .sheet(item: $shownCall) { ref in
            if let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                CallSheet(sessionID: anatomy.sessionId, lane: lane, index: ref.index)
            }
        }
    }

    private static let buttonSize: CGFloat = 22

    private enum Column { case agent, model, start, time, tokens, tools, compactions, cost, day, week }

    private static func ascending(_ column: Column, _ a: AnatomyLane, _ b: AnatomyLane) -> Bool {
        switch column {
        case .agent: a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .model: (a.model ?? "") < (b.model ?? "")
        case .start: (a.startedAt ?? .distantPast) < (b.startedAt ?? .distantPast)
        case .time: a.duration < b.duration
        case .tokens: a.usage.total < b.usage.total
        case .tools: a.toolCalls < b.toolCalls
        case .compactions: a.compactions < b.compactions
        // A session's limits are shares of the cost.
        case .cost, .day, .week: a.costMicros < b.costMicros
        }
    }

    /// The agent's column takes the room the others leave.
    private func columns(_ widths: Widths, @ViewBuilder agent: () -> some View, @ViewBuilder cells: () -> some View) -> some View {
        HStack(spacing: 14) {
            agent().frame(maxWidth: .infinity, alignment: .leading)
            cells()
        }
    }

    /// One row's texts.
    fileprivate struct Line {
        var lane: AnatomyLane
        var model: String
        var start: String
        var time: String
        var tokens: String
        var tools: String
        var errors: String?
        var cost: String
        var day: String?
        var week: String?
        var toolsText: String { errors.map { "\(tools) · \($0)" } ?? tools }
    }

    private func line(_ lane: AnatomyLane) -> Line {
        let parts = Plan.limitParts(costMicros: lane.costMicros, weeklyBudgetMicros: model.plan.weeklyBudgetMicros)
        return Line(lane: lane, model: shortModel(lane.model) ?? "",
                    start: lane.startedAt?.formatted(date: .omitted, time: .shortened) ?? "",
                    time: shortDuration(lane.duration), tokens: Format.tokens(lane.usage.total),
                    tools: "\(lane.toolCalls)", errors: lane.errors > 0 ? plural(Int(lane.errors), "error") : nil,
                    cost: Format.dollars(lane.costMicros), day: parts?.day, week: parts?.week)
    }

    /// The columns' widths: as wide as the widest title or value, so that they
    /// line up from row to row and a whole row can take a right click.
    fileprivate struct Widths {
        var model, start, time, tokens, tools, compactions, cost, day, week: CGFloat

        init(_ lines: [Line], hasLimit: Bool) {
            let title = NSFont.systemFont(ofSize: 11, weight: .medium)
            let plain = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
            let bold = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
            func width(_ name: String, _ font: NSFont, _ value: (Line) -> String) -> CGFloat {
                max(textWidth(name, title) + SortTitle<Column>.arrowRoom, lines.map { textWidth(value($0), font) }.max() ?? 0)
            }
            model = width("Model", plain) { $0.model }
            start = width("Start", plain) { $0.start }
            time = width("Time", plain) { $0.time }
            tokens = width("Tokens", plain) { $0.tokens }
            tools = width("Tools", plain) { $0.toolsText }
            compactions = width("Compactions", plain) { "\($0.lane.compactions)" }
            cost = width("Cost", bold) { $0.cost }
            day = hasLimit ? width("Day limit", plain) { $0.day ?? "" } : 0
            week = hasLimit ? width("Week limit", plain) { $0.week ?? "" } : 0
        }
    }

    private func row(_ line: Line, _ widths: Widths) -> some View {
        let lane = line.lane
        let spawn = anatomy.spawnPlace(of: lane)
        return columns(widths) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.agent).frame(width: 3, height: 14)
                Text(lane.name).lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, CGFloat(max(0, anatomy.depth(of: lane) - 1)) * 14)
            .help([lane.name, lane.agentType].compactMap { $0 }.joined(separator: "\n"))
        } cells: {
            Text(line.model).foregroundStyle(Theme.text2).frame(width: widths.model, alignment: .leading)
            Text(line.start).frame(width: widths.start, alignment: .trailing)
            Text(line.time).frame(width: widths.time, alignment: .trailing)
            Text(line.tokens).frame(width: widths.tokens, alignment: .trailing)
            Group {
                if let errors = line.errors {
                    Text("\(line.tools) · ") + Text(errors).foregroundStyle(Theme.bad)
                } else {
                    Text(line.tools)
                }
            }
            .frame(width: widths.tools, alignment: .trailing)
            // Most agents have none, so a 0 stays quiet and a real number stands out.
            Text("\(lane.compactions)")
                .foregroundStyle(lane.compactions == 0 ? Theme.text3 : Theme.text)
                .frame(width: widths.compactions, alignment: .trailing)
            Text(line.cost).fontWeight(.medium).frame(width: widths.cost, alignment: .trailing)
            if hasLimit {
                Text(line.day ?? "").foregroundStyle(Theme.text2).frame(width: widths.day, alignment: .trailing)
                Text(line.week ?? "").foregroundStyle(Theme.text2).frame(width: widths.week, alignment: .trailing)
            }
            SmallIconButton(symbol: "bubble.left.and.text.bubble.right", help: "Open this agent alone in Chat",
                            size: Self.buttonSize, fill: Theme.bg) {
                model.chatLane = lane.id
                model.windowTab = .chat
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .hoverRow()
        .rowMenu(view: spawn.flatMap { place in
                     anatomy.lane(place.lane)?.events[place.event].hasFullCall == true
                         ? { shownCall = CallRef(lane: place.lane, index: place.event) } : nil
                 },
                 goTo: { model.openInChat(spawn ?? ChatPlace(lane: lane.id, event: 0)) },
                 fileName: RowExport.fileName(sessionID: anatomy.sessionId, name: lane.name),
                 json: { try RowExport.encode(RowExport.subagent(lane, in: anatomy)) })
    }
}
