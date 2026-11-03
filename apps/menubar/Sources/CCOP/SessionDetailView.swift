import CCOPKit
import SwiftUI

/// One session: in the popover a compact view with a bar of actions (board
/// "Popover · one session"); in the window the Overview tab (board
/// "Window · Overview").
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// In the main window: no back button, the window has tabs.
    let inWindow: Bool
    @State private var wide = true

    var body: some View {
        Group {
            if inWindow { overview } else { popover }
        }
        .task(id: "\(session.id) \(session.modifiedAt.timeIntervalSince1970)") { model.loadAnatomy(session) }
    }

    private var anatomy: Anatomy? {
        if case let .loaded(a, _) = model.anatomies[session.id] { return a }
        return nil
    }

    // MARK: Popover

    private var popover: some View {
        let s = session
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.selectedID = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Sessions")
                    }
                    .font(.ui(13, .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if s.active { ActivePill() }
                Button { model.openWindow?(s.id, .overview) } label: { IconLabel(title: "Open in window", symbol: "macwindow") }
                    .buttonStyle(DesignButtonStyle(kind: .bordered, height: 26, padding: 10, fontSize: 12))
                    .help("Open this session in the main window")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(.ui(17, .semibold)).tracking(-0.17).textSelection(.enabled).lineLimit(3)
                        Text(metaLine(s)).font(.ui(12)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        StatCard(label: "Cost", value: Format.dollars(s.costMicros))
                        StatCard(label: "Tokens", value: Format.tokens(s.usage.total))
                        StatCard(label: "Model calls", value: "\(s.usage.requests)")
                        StatCard(label: "From cache", value: Format.percent(s.usage.cacheHitRatio))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        UsageBar(usage: s.usage, legend: false)
                        UsageTable(session: s, anatomy: anatomy, compact: true)
                    }
                    TopTipLink(session: s)
                    if let p = s.lastPrompt ?? s.firstPrompt {
                        VStack(alignment: .leading, spacing: 3) {
                            Text((s.lastPrompt != nil ? "Last prompt" : "First prompt").uppercased())
                                .font(.ui(11, .semibold)).tracking(0.44).foregroundStyle(Theme.text3)
                            Text(p).lineSpacing(2.5).lineLimit(4).textSelection(.enabled)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                        GridRow { label("Project", 22); CopyableValue(text: Theme.shortPath(s.projectDir), help: "Copy the project path") }
                        GridRow { label("Prompts", 22); value(promptsLine(s), 22) }
                        GridRow { label("Transcript", 22); value(transcriptLine(s), 22) }
                        GridRow { label("Session id", 22); CopyableValue(text: s.id, help: "Copy the session id") }
                    }
                    .font(.ui(12))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 8) {
                Button { model.resumeInTerminal(s) } label: { IconLabel(title: "Resume in Terminal", symbol: "terminal", iconSize: 14) }
                    .buttonStyle(DesignButtonStyle(kind: .primary, height: 28, padding: 12))
                Button { model.copyResumeCommand(s) } label: { IconLabel(title: "Copy command", symbol: "doc.on.doc", iconSize: 14) }
                    .buttonStyle(DesignButtonStyle(kind: .bordered, height: 28, padding: 10))
                    .help(Resume.command(s))
                Spacer()
                SmallIconButton(symbol: "doc.text", help: "Show the transcript in Finder", size: 28, fill: Theme.bg) { model.revealTranscript(s) }
                SmallIconButton(symbol: "folder", help: "Open the project folder", size: 28, fill: Theme.bg) { model.openProjectFolder(s) }
                SmallIconButton(symbol: "number", help: "Copy the session id", size: 28, fill: Theme.bg) { model.copy(s.id) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bg)
        }
    }

    // MARK: Window

    private var overview: some View {
        let s = session
        let a = anatomy
        return PageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    StatCard(label: "API-equivalent cost", value: Format.dollars(s.costMicros), detail: limitShare(s), big: true)
                    StatCard(label: "Tokens", value: Format.tokens(s.usage.total),
                             detail: "\(Format.percent(s.usage.cacheHitRatio)) of input from cache", big: true)
                    StatCard(label: "Model calls", value: "\(s.usage.requests)", detail: callsLine(s), big: true)
                    StatCard(label: "Average context", value: a?.contextSize.map { Format.tokens($0.average) } ?? "–",
                             detail: a.flatMap(contextLine), big: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tokens by kind").font(.ui(13, .semibold))
                    UsageBar(usage: s.usage, legend: false, height: 8)
                    UsageTable(session: s, anatomy: a, compact: false)
                }
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
                    Button("Show transcript") { model.revealTranscript(s) }
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 30, radius: 7, padding: 12))
                    Button("Open folder") { model.openProjectFolder(s) }
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 30, radius: 7, padding: 12))
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
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

    private func metaLine(_ s: Session) -> String {
        var parts = [s.projectName]
        if let b = s.gitBranch { parts.append(b) }
        let last = "last activity \(Format.ago(s.lastActivity, now: model.now))"
        if let t = s.startedAt {
            parts.append("started \(t.formatted(date: .omitted, time: .shortened)), \(last)")
        } else {
            parts.append(last)
        }
        return parts.joined(separator: " · ")
    }

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
        let n = a.lane("main")?.events.filter { $0.kind == .compact }.count ?? 0
        return "max \(Format.tokens(c.max)) · \(n) compaction\(n == 1 ? "" : "s")"
    }

    private func limitShare(_ s: Session) -> String? {
        guard let b = model.plan.weeklyBudgetMicros, b > 0 else { return nil }
        return "\(Format.percent(Double(s.costMicros) / Double(b))) of your weekly limit"
    }
}

/// A green "Active" label.
struct ActivePill: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.ok).frame(width: 6, height: 6)
            Text("Active")
        }
        .font(.ui(11, .medium))
        .foregroundStyle(Theme.ok)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Theme.ok.opacity(0.10), in: Capsule())
    }
}

/// The biggest saving from the Spend tab, as a link to it. Loads the
/// session's anatomy when shown.
struct TopTipLink: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        Group {
            if case let .loaded(a, _) = model.anatomies[session.id], let tip = Self.best(a.spend.tips) {
                Button { model.openWindow?(session.id, .spend) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb").font(.system(size: 16)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(headline(tip)).font(.ui(13, .semibold)).lineLimit(1)
                            Text(more(a.spend.tips.count)).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent.opacity(0.18)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tip.detail)
            }
        }
        .task(id: "\(session.id) \(session.modifiedAt.timeIntervalSince1970)") { model.loadAnatomy(session) }
    }

    static func best(_ tips: [Tip]) -> Tip? {
        tips.max { ($0.savingMicros ?? 0, $0.costMicros) < ($1.savingMicros ?? 0, $1.costMicros) }
    }

    private func headline(_ tip: Tip) -> String {
        if let s = tip.savingMicros, s > 0 { return "Save up to \(Format.dollars(s)): \(tip.title)" }
        return tip.title
    }

    private func more(_ count: Int) -> String {
        count > 1 ? "\(count - 1) more tip\(count == 2 ? "" : "s") in Spend." : "Details in Spend."
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
    let anatomy: Anatomy
    @State private var showAll = false

    private static let firstRows = 12

    var body: some View {
        let lanes = anatomy.lanesInTreeOrder.filter { $0.id != "main" }
        let shown = showAll ? lanes : Array(lanes.prefix(Self.firstRows))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Subagents").font(.ui(13, .semibold))
                Text("\(lanes.count) · \(Format.dollars(anatomy.subagentCostMicros))")
                    .font(.ui(11)).foregroundStyle(Theme.text3).monospacedDigit()
            }
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text("Agent").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Start")
                    Text("Time")
                    Text("Tokens")
                    Text("Tools")
                    Text("Cost")
                    Text("")
                }
                .font(.ui(11, .medium))
                .foregroundStyle(Theme.text3)
                .padding(.vertical, 6)
                ForEach(shown) { lane in
                    Rectangle().fill(Theme.line2).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    row(lane)
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
    }

    private func row(_ lane: AnatomyLane) -> some View {
        GridRow {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.agent).frame(width: 3, height: 14)
                Text(lane.name).lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, CGFloat(max(0, anatomy.depth(of: lane) - 1)) * 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help([lane.name, lane.agentType].compactMap { $0 }.joined(separator: "\n"))
            Text(shortModel(lane.model) ?? "").foregroundStyle(Theme.text2)
            Text(lane.startedAt?.formatted(date: .omitted, time: .shortened) ?? "")
            Text(shortDuration(lane.duration))
            Text(Format.tokens(lane.usage.total))
            if lane.errors > 0 {
                (Text("\(lane.toolCalls) · ") + Text(plural(Int(lane.errors), "error")).foregroundStyle(Theme.bad))
            } else {
                Text("\(lane.toolCalls)")
            }
            Text(Format.dollars(lane.costMicros)).fontWeight(.medium)
            SmallIconButton(symbol: "bubble.left.and.text.bubble.right", help: "Open this agent alone in Chat",
                            size: 22, fill: Theme.bg) {
                model.chatLane = lane.id
                model.windowTab = .chat
            }
        }
        .monospacedDigit()
        .padding(.vertical, 5)
    }
}
