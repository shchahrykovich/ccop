import CCOPKit
import SwiftUI

/// One session: facts, tokens by model, prompts, and actions.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// In the main window: no back button, the window has tabs.
    let inWindow: Bool

    var body: some View {
        let s = session
        VStack(spacing: 0) {
            if !inWindow {
                HStack {
                    Button { model.selectedID = nil } label: { Label("Sessions", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                    if s.active { Label("Active", systemImage: "circle.fill").foregroundStyle(.green).font(.caption) }
                    Button { model.openWindow?(s.id, .anatomy) } label: { Label("Anatomy", systemImage: "chart.bar.doc.horizontal") }
                        .help("Open the timeline of this session in a window")
                    Button { model.openWindow?(s.id, .context) } label: { Label("Context", systemImage: "square.stack.3d.up") }
                        .help("Open what filled the context of this session in a window")
                }
                .padding(12)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(s.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    facts(s)
                    TotalsBlock(session: s)
                    UsageTable(session: s)
                    prompts(s)
                    actions(s)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func facts(_ s: Session) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Project", s.projectDir)
            if let b = s.gitBranch { row("Branch", b) }
            if let t = s.startedAt { row("Started", t.formatted(date: .abbreviated, time: .shortened)) }
            row("Last activity", "\(s.lastActivity.formatted(date: .abbreviated, time: .shortened)) (\(Format.ago(s.lastActivity, now: model.now)))")
            row("Prompts", "\(s.prompts) typed, \(s.usage.requests) model calls, \(s.subagents) subagent\(s.subagents == 1 ? "" : "s")")
            row("Transcript", Format.bytes(s.sizeBytes))
            if let v = s.version { row("Claude Code", v) }
            row("Session id", s.id)
            if let next = s.continuedIn {
                GridRow {
                    Text("Continued in").foregroundStyle(.secondary)
                    Button(String(next.prefix(8))) {
                        if inWindow { model.windowSelectedID = next } else { model.selectedID = next }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }

    @ViewBuilder
    private func prompts(_ s: Session) -> some View {
        if let p = s.firstPrompt {
            VStack(alignment: .leading, spacing: 4) {
                Text("First prompt").font(.caption).foregroundStyle(.secondary)
                Text(p).textSelection(.enabled)
            }
        }
        if let p = s.lastPrompt, p != s.firstPrompt {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last prompt").font(.caption).foregroundStyle(.secondary)
                Text(p).textSelection(.enabled)
            }
        }
    }

    private func actions(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.resumeInTerminal(s) } label: { Label("Resume in Terminal", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                Button { model.copyResumeCommand(s) } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
            }
            HStack {
                Button { model.revealTranscript(s) } label: { Label("Show transcript", systemImage: "doc.text.magnifyingglass") }
                Button { model.openProjectFolder(s) } label: { Label("Open folder", systemImage: "folder") }
                Button { model.copy(s.id) } label: { Label("Copy id", systemImage: "number") }
            }
        }
    }
}

struct TotalsBlock: View {
    let session: Session

    var body: some View {
        let u = session.usage
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.tokens(u.total)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("tokens").foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.percent(u.cacheHitRatio)) of input from cache").font(.caption).foregroundStyle(.secondary)
            }
            UsageBar(usage: u)
        }
    }
}

/// Tokens by kind for the whole session, its subagents, and each model.
struct UsageTable: View {
    let session: Session

    var body: some View {
        let rows: [(String, TokenUsage)] = [("All", session.usage)]
            + (session.subagents > 0 ? [("Subagents", session.subagentUsage)] : [])
            + session.models.map { ($0.model, $0.usage) }
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("Input")
                Text("Cache write")
                Text("Cache read")
                Text("Output")
                Text("Calls")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.0) { name, u in
                GridRow {
                    Text(name).lineLimit(1).fontWeight(name == "All" ? .semibold : .regular)
                    Text(Format.tokens(u.inputTokens))
                    Text(Format.tokens(u.cacheWriteTokens))
                    Text(Format.tokens(u.cacheReadTokens))
                    Text(Format.tokens(u.outputTokens))
                    Text("\(u.requests)")
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }
}
