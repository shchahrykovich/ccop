import CCOPKit
import SwiftUI

/// One session: in the popover a compact view with a bar of actions; in the
/// window the Overview tab.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// In the main window: no back button, the window has tabs.
    let inWindow: Bool

    var body: some View {
        if inWindow { overview } else { popover }
    }

    // MARK: Popover

    private var popover: some View {
        let s = session
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.selectedID = nil } label: { Label("Sessions", systemImage: "chevron.left").fontWeight(.medium) }
                    .buttonStyle(.borderless)
                Spacer()
                if s.active { ActivePill() }
                Button { model.openWindow?(s.id, .overview) } label: { Label("Open in window", systemImage: "macwindow") }
                    .controlSize(.small)
                    .help("Open this session in the main window")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled).lineLimit(3)
                        Text(metaLine(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        StatCard(label: "Cost", value: Format.dollars(s.costMicros))
                        StatCard(label: "Tokens", value: Format.tokens(s.usage.total))
                        StatCard(label: "Model calls", value: "\(s.usage.requests)")
                        StatCard(label: "From cache", value: Format.percent(s.usage.cacheHitRatio))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        UsageBar(usage: s.usage, legend: false)
                        UsageTable(session: s, compact: true)
                    }
                    TopTipLink(session: s)
                    if let p = s.lastPrompt ?? s.firstPrompt {
                        VStack(alignment: .leading, spacing: 3) {
                            SectionLabel(s.lastPrompt != nil ? "Last prompt" : "First prompt")
                            Text(p).lineLimit(4).textSelection(.enabled)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        GridRow { label("Project"); CopyableValue(text: s.projectDir, help: "Copy the project path") }
                        if let b = s.gitBranch { GridRow { label("Branch"); CopyableValue(text: b, help: "Copy the branch name") } }
                        GridRow { label("Prompts"); Text(promptsLine(s)).font(.callout) }
                        GridRow { label("Transcript"); Text([Format.bytes(s.sizeBytes), s.version.map { "Claude Code \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.callout) }
                        GridRow { label("Session id"); CopyableValue(text: s.id, help: "Copy the session id") }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                Button { model.resumeInTerminal(s) } label: { Label("Resume in Terminal", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                Button { model.copyResumeCommand(s) } label: { Label("Copy command", systemImage: "doc.on.doc") }
                    .help(Resume.command(s))
                Spacer()
                iconButton("doc.text.magnifyingglass", "Show the transcript in Finder") { model.revealTranscript(s) }
                iconButton("folder", "Open the project folder") { model.openProjectFolder(s) }
                iconButton("number", "Copy the session id") { model.copy(s.id) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: Window

    private var overview: some View {
        let s = session
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    StatCard(label: "API-equivalent cost", value: Format.dollars(s.costMicros), detail: limitShare(s), big: true)
                    StatCard(label: "Tokens", value: Format.tokens(s.usage.total),
                             detail: "\(Format.percent(s.usage.cacheHitRatio)) of input from cache", big: true)
                    StatCard(label: "Model calls", value: "\(s.usage.requests)", detail: callsLine(s), big: true)
                    StatCard(label: "Prompts", value: "\(s.prompts)",
                             detail: "\(s.subagents) subagent\(s.subagents == 1 ? "" : "s")", big: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tokens by kind").font(.headline)
                    UsageBar(usage: s.usage, height: 8)
                    UsageTable(session: s, compact: false)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) { facts(s); prompts(s) }
                    VStack(alignment: .leading, spacing: 22) { facts(s); prompts(s) }
                }
                HStack(spacing: 8) {
                    Button { model.resumeInTerminal(s) } label: { Label("Resume in Terminal", systemImage: "terminal") }
                        .buttonStyle(.borderedProminent)
                    Button { model.copyResumeCommand(s) } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
                    Button { model.revealTranscript(s) } label: { Label("Show transcript", systemImage: "doc.text.magnifyingglass") }
                    Button { model.openProjectFolder(s) } label: { Label("Open folder", systemImage: "folder") }
                }
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Facts").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow { label("Project"); CopyableValue(text: s.projectDir, help: "Copy the project path") }
                if let b = s.gitBranch { GridRow { label("Branch"); CopyableValue(text: b, help: "Copy the branch name") } }
                if let t = s.startedAt { GridRow { label("Started"); Text(t.formatted(date: .abbreviated, time: .shortened)).font(.callout) } }
                GridRow {
                    label("Last activity")
                    Text("\(s.lastActivity.formatted(date: .abbreviated, time: .shortened)) (\(Format.ago(s.lastActivity, now: model.now)))").font(.callout)
                }
                GridRow { label("Prompts"); Text(promptsLine(s)).font(.callout) }
                GridRow { label("Transcript"); Text(Format.bytes(s.sizeBytes)).font(.callout) }
                if let v = s.version { GridRow { label("Claude Code"); Text(v).font(.callout) } }
                GridRow { label("Session id"); CopyableValue(text: s.id, help: "Copy the session id") }
                if let next = s.continuedIn {
                    GridRow {
                        label("Continued in")
                        Button(String(next.prefix(8))) { model.windowSelectedID = next }.buttonStyle(.link)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prompts(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompts").font(.headline)
            if let p = s.firstPrompt { promptCard("First", p, s.startedAt) }
            if let p = s.lastPrompt, p != s.firstPrompt { promptCard("Last", p, nil) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promptCard(_ title: String, _ text: String, _ at: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([title, at.map { $0.formatted(date: .omitted, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled).lineLimit(8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardStroke))
    }

    // MARK: Parts

    private func label(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }
            .help(help)
            .accessibilityLabel(help)
    }

    private func metaLine(_ s: Session) -> String {
        var parts = [s.projectName]
        if let b = s.gitBranch { parts.append(b) }
        if let t = s.startedAt { parts.append("started \(t.formatted(date: .omitted, time: .shortened))") }
        parts.append("last activity \(Format.ago(s.lastActivity, now: model.now))")
        return parts.joined(separator: " · ")
    }

    private func promptsLine(_ s: Session) -> String {
        "\(s.prompts) typed, \(s.usage.requests) model calls, \(s.subagents) subagent\(s.subagents == 1 ? "" : "s")"
    }

    private func callsLine(_ s: Session) -> String {
        let sub = s.subagentUsage.requests
        guard sub > 0 else { return "all in the main session" }
        return "\(s.usage.requests - min(sub, s.usage.requests)) main · \(sub) in subagents"
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
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.ok)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Theme.ok.opacity(0.12), in: Capsule())
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
                        Image(systemName: "lightbulb").font(.system(size: 16)).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline(tip)).fontWeight(.semibold).lineLimit(1)
                            Text(more(a.spend.tips.count)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(0.2)))
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

/// Tokens by kind for the whole session, its subagents, and each model.
struct UsageTable: View {
    let session: Session
    var compact = false

    var body: some View {
        let rows: [(String, TokenUsage, String?)] = [("All", session.usage, Format.dollars(session.costMicros))]
            + (session.subagents > 0 ? [("Subagents", session.subagentUsage, nil)] : [])
            + session.models.map { (compact ? $0.model.replacingOccurrences(of: "claude-", with: "") : $0.model, $0.usage, nil) }
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: compact ? 4 : 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                head("Input", Theme.input)
                head("Cache write", Theme.cacheWrite)
                head("Cache read", Theme.cacheRead)
                head("Output", Theme.output)
                Text("Calls")
                Text("Cost")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.0) { name, u, cost in
                GridRow {
                    Text(name).lineLimit(1).fontWeight(name == "All" ? .semibold : .regular)
                        .font(name.contains("-") ? .system(compact ? .caption : .callout, design: .monospaced) : nil)
                    Text(Format.tokens(u.inputTokens))
                    Text(Format.tokens(u.cacheWriteTokens))
                    Text(Format.tokens(u.cacheReadTokens))
                    Text(Format.tokens(u.outputTokens))
                    Text("\(u.requests)")
                    Text(cost ?? "").fontWeight(.semibold)
                }
                .monospacedDigit()
            }
        }
        .font(compact ? .caption : .callout)
    }

    private func head(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }
}
