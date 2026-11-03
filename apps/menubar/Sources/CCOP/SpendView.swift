import CCOPKit
import SwiftUI

/// The Spend tab: where the cost of a session went, and what to change.
/// The numbers come from libs/core/src/spend.rs.
struct SpendView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let anatomy: Anatomy

    var body: some View {
        let s = anatomy.spend
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(s)
                TipList(spend: s)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        CauseTable(spend: s).frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity, alignment: .topLeading)
                        PromptCosts(anatomy: anatomy).frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        CauseTable(spend: s)
                        PromptCosts(anatomy: anatomy)
                    }
                }
                if !s.commands.isEmpty { CommandTable(session: session, anatomy: anatomy) }
                if !s.errors.isEmpty { ErrorTable(spend: s) }
                if anatomy.lanes.count > 1 { LaneCosts(anatomy: anatomy) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ s: Spend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(Format.dollars(s.costMicros))
                    .font(.system(size: 28, weight: .semibold)).tracking(-0.5).monospacedDigit()
                    .help("API-equivalent cost")
                Text("Every model call reads the whole context again. So a session costs about: model calls × context size. Each call's cost goes to what made the model run.")
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(facts(s))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .help("Cost is at API prices, so a cheap cache read weighs less than an output token. What made the model run: a tool result, your message, or the task a subagent got.")
        }
    }

    /// The smaller numbers under the cost: weekly limit share, tokens, model calls.
    private func facts(_ s: Spend) -> String {
        var parts = ["API-equivalent cost"]
        if let budget = model.plan.weeklyBudgetMicros, budget > 0 {
            parts.append("\(Format.percent(Double(s.costMicros) / Double(budget))) of your weekly limit")
        }
        parts.append("\(Format.tokens(s.tokens)) tokens")
        parts.append("\(s.lanes.reduce(0) { $0 + $1.modelCalls }) model calls")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shared parts

/// A section title with a short grey note beside it.
private struct SectionHeader: View {
    let title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The small grey column titles of a table.
private struct ColumnTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }
}

/// A thin line between table rows; it spans every column of a `Grid`.
private struct RowLine: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
    }
}

private let rowFont = Font.system(size: 12.5)

/// A part of the whole, as a short bar.
struct ShareBar: View {
    let share: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, share))))
            }
        }
        .frame(width: 90, height: 6)
    }
}

// MARK: - Tips

struct TipList: View {
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What to change", note: summary)
            if spend.tips.isEmpty {
                Text("ccop found nothing large to change in this session.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(spend.tips) { TipCard(tip: $0, spend: spend) }
                }
            }
        }
    }

    /// "3 tips · save up to $3.45 (43%)". Savings can overlap, so their sum is capped at the session's cost.
    private var summary: String? {
        guard !spend.tips.isEmpty else { return nil }
        let count = spend.tips.count == 1 ? "1 tip" : "\(spend.tips.count) tips"
        let saving = min(spend.costMicros, spend.tips.reduce(0) { $0 + ($1.savingMicros ?? 0) })
        guard saving > 0 else { return count }
        return "\(count) · save up to \(Format.dollars(saving)) (\(Format.percent(spend.share(saving))))"
    }
}

/// One tip: the saving (or the cost) first, then the title and what to do.
private struct TipCard: View {
    let tip: Tip
    let spend: Spend

    var body: some View {
        let saving = tip.savingMicros
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let saving {
                    Text("−\(Format.dollars(saving))")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text("\(Format.percent(spend.share(saving))) of the session")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(Format.dollars(tip.costMicros))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tip.kind == .errors ? Theme.bad : Color.primary)
                    Text("\(Format.percent(spend.share(tip.costMicros))) \(tip.kind == .errors ? "spent on errors" : "of the session")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Text(tip.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            Text(tip.detail)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(saving != nil ? Color.accentColor.opacity(0.07) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(saving != nil ? Color.accentColor.opacity(0.22) : Theme.cardStroke))
    }
}

// MARK: - Causes

/// What made the model run, the most cost first, as bars relative to the biggest cause.
struct CauseTable: View {
    let spend: Spend

    var body: some View {
        let causes = spend.causes.filter { $0.costMicros > 0 || $0.count > 0 }.sorted { $0.costMicros > $1.costMicros }
        let top = max(1, causes.first?.costMicros ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "By cause")
                .help("After a tool result the model runs again and reads the whole context. A call after several results counts a part for each. Point at a row for its numbers.")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(causes) { c in
                    let look = look(c)
                    GridRow {
                        IconTile(symbol: look.symbol, color: look.color, size: 24)
                        Text(label(c)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                        Meter(value: Double(c.costMicros) / Double(top), color: look.color, height: 8)
                            .frame(minWidth: 40, maxWidth: .infinity)
                        Text(Format.dollars(c.costMicros)).fontWeight(.medium)
                            .gridColumnAlignment(.trailing)
                    }
                    .font(rowFont)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .help(help(c))
                }
            }
        }
    }

    private func label(_ c: Cause) -> String {
        switch c.kind {
        case .tool: "\(c.name) results"
        case .prompt: "Your messages"
        case .task: "Subagent tasks"
        case .compact: "Compaction"
        case .other: "Start"
        }
    }

    private func look(_ c: Cause) -> (color: Color, symbol: String) {
        switch c.kind {
        case .tool: Theme.tool(c.name)
        case .prompt: (Theme.prompt, "text.bubble")
        case .task: (Theme.agent, "point.3.connected.trianglepath.dotted")
        case .compact: (Theme.warn, "arrow.down.right.and.arrow.up.left")
        case .other: (Color.secondary, "flag")
        }
    }

    private func help(_ c: Cause) -> String {
        let what = switch c.kind {
        case .prompt: "Model calls right after one of your messages."
        case .task: "The first call of a subagent, after the task its lead gave it."
        case .compact: "Model calls right after a compaction."
        case .other: "Model calls with nothing new before them in their lane: the start, with the system prompt."
        case .tool:
            c.errorCostMicros > 0
                ? "Model calls after \(c.name) results. \(Format.dollars(c.errorCostMicros)) of it came after failed calls."
                : "Model calls after \(c.name) results."
        }
        var lines = [what, "\(Format.dollars(c.costMicros)), \(Format.percent(spend.share(c.costMicros))) of the session."]
        if c.count > 0 { lines.append("Count: \(c.count)" + (c.errors > 0 ? ", \(c.errors) failed" : "")) }
        lines.append("Model calls: \(Int(c.modelCalls.rounded()))")
        if c.avgContext > 0 { lines.append("Avg context: \(Format.tokens(c.avgContext))") }
        if c.addedTokens > 0 { lines.append("Context added: \(Format.tokens(c.addedTokens)) (estimated)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Your messages

/// Each of your prompts and what its turn cost, with the subagents it started.
struct PromptCosts: View {
    let anatomy: Anatomy
    @State private var showAll = false
    private let shownAtFirst = 8

    var body: some View {
        let turns = anatomy.turns
        let shown = showAll ? turns : Array(turns.prefix(shownAtFirst))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Your messages", note: "the main session's calls until your next message")
                .help("Cost: the main session's calls until your next message, and the subagents started in that time. Point at a row for the split.")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    ColumnTitle("#")
                    ColumnTitle("Time")
                    ColumnTitle("Message")
                    ColumnTitle("Calls").gridColumnAlignment(.trailing)
                    ColumnTitle("Cost").gridColumnAlignment(.trailing)
                }
                ForEach(shown) { t in
                    RowLine()
                    GridRow {
                        Text(t.index > 0 ? "\(t.index)" : "").foregroundStyle(.secondary)
                        Text(t.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        Text(t.prompt.isEmpty ? "(before your first message)" : t.prompt)
                            .lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(t.prompt.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(t.answers)")
                        Text(Format.dollars(t.totalCostMicros)).fontWeight(.medium)
                    }
                    .font(rowFont)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .help(help(t))
                }
            }
            if turns.count > shownAtFirst {
                Button(showAll ? "Show fewer" : "Show \(turns.count - shownAtFirst) more") { showAll.toggle() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    private func help(_ t: Turn) -> String {
        var lines = [t.prompt, ""]
        lines.append("Main session: \(Format.dollars(t.costMicros)) in \(t.answers) model calls, \(t.toolCalls) tool calls")
        if !t.subagents.isEmpty {
            lines.append("Subagents: \(Format.dollars(t.subagentCostMicros)) in \(t.subagents.count)")
        }
        lines.append("Total: \(Format.dollars(t.totalCostMicros)), \(Format.percent(anatomy.spend.share(t.totalCostMicros))) of the session")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Bash commands

/// Bash calls by the program they ran. A row opens the list of its calls;
/// a call opens its input, output and consumption.
struct CommandTable: View {
    let session: Session
    let anatomy: Anatomy
    @State private var showAll = false
    @State private var open: Set<String> = []
    @State private var shownCall: CallRef?

    var body: some View {
        let spend = anatomy.spend
        let shown = showAll ? spend.commands : Array(spend.commands.prefix(12))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Bash commands", note: "by program. Click a program to see each call.")
                .help("Bash calls by the program they ran (after `cd <folder> &&`). Cost: the model calls after their results. Context added: tokens the output put into the context (estimated). Click a call to see its whole input and output.")
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ColumnTitle("Program").gridColumnAlignment(.leading)
                    ColumnTitle("Calls")
                    ColumnTitle("Context added")
                    ColumnTitle("Errors")
                    ColumnTitle("Cost")
                }
                ForEach(shown) { g in
                    let isOpen = open.contains(g.group)
                    RowLine()
                    GridRow {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(.secondary)
                            Text(g.group).lineLimit(1).font(.system(size: 12.5, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(g.calls)")
                        Text(added(g).map { Format.tokens($0) } ?? "")
                        Text("\(g.errors)").foregroundStyle(g.errors > 0 ? Theme.bad : .secondary)
                        Text(Format.dollars(g.costMicros)).fontWeight(.medium)
                    }
                    .font(rowFont)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .help(help(g))
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if isOpen { open.remove(g.group) } else { open.insert(g.group) }
                        }
                    }
                    if isOpen {
                        GridRow {
                            CallList(anatomy: anatomy, items: g.items, shownCall: $shownCall)
                                .gridCellColumns(5)
                        }
                    }
                }
            }
            if spend.commands.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(spend.commands.count)") { showAll.toggle() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
        .sheet(item: $shownCall) { ref in
            if let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                CallSheet(sessionID: session.id, lane: lane, index: ref.index)
            }
        }
    }

    /// Tokens the group's outputs put into the context (estimated), from each call's event.
    private func added(_ g: CCOPKit.CommandGroup) -> UInt64? {
        var sum: UInt64 = 0
        var any = false
        for item in g.items {
            if let lane = anatomy.lane(item.lane), lane.events.indices.contains(item.event),
               let a = lane.events[item.event].addedTokens {
                sum += a
                any = true
            }
        }
        return any ? sum : nil
    }

    private func help(_ g: CCOPKit.CommandGroup) -> String {
        var lines = [
            "\(Format.dollars(g.costMicros)), \(Format.percent(anatomy.spend.share(g.costMicros))) of the session",
            "Avg output: \(Format.bytes(g.calls == 0 ? 0 : g.resultBytes / g.calls))",
        ]
        if let ex = g.example { lines.append("Example: \(ex)") }
        return lines.joined(separator: "\n")
    }
}

/// The calls of one program: when, which agent, the command, and what each one cost.
struct CallList: View {
    let anatomy: Anatomy
    let items: [CallCost]
    @Binding var shownCall: CallRef?
    @State private var byCost = false

    var body: some View {
        let rows = byCost ? items.sorted { $0.costMicros > $1.costMicros } : items
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(items.count) calls. Added: tokens the output put into the context (estimated). Cost: its part of the model call after it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Order", selection: $byCost) {
                    Text("By time").tag(false)
                    Text("By cost").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160).controlSize(.small)
            }
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    ColumnTitle("Time")
                    ColumnTitle("Agent").gridColumnAlignment(.leading)
                    ColumnTitle("Command").gridColumnAlignment(.leading)
                    ColumnTitle("Output")
                    ColumnTitle("Added")
                    ColumnTitle("Cost")
                }
                ForEach(rows, id: \.self) { item in
                    if let lane = anatomy.lane(item.lane), lane.events.indices.contains(item.event) {
                        let e = lane.events[item.event]
                        GridRow {
                            Text(e.start.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                            Text(lane.name).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                            Text(e.command ?? e.text ?? "").font(.caption.monospaced()).lineLimit(1)
                                .foregroundStyle(e.isError ? Theme.bad : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help([e.text, e.command, e.error].compactMap { $0 }.joined(separator: "\n\n"))
                            Text(e.resultBytes.map { Format.bytes($0) } ?? "")
                            Text(e.addedTokens.map { Format.tokens($0) } ?? "")
                            Text(Format.dollars(item.costMicros)).fontWeight(.medium)
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .contentShape(Rectangle())
                        .onTapGesture { shownCall = CallRef(lane: item.lane, index: item.event) }
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke))
        .padding(.vertical, 2)
    }
}

// MARK: - Errors

/// Failed tool calls, grouped by the start of their error text.
struct ErrorTable: View {
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Errors", note: "failed tool calls whose error text starts the same way. Cost: the model calls after them, which usually try again.")
            Grid(alignment: .topTrailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ColumnTitle("Times")
                    ColumnTitle("Tool").gridColumnAlignment(.leading)
                    ColumnTitle("Error").gridColumnAlignment(.leading)
                    ColumnTitle("Cost")
                }
                ForEach(spend.errors) { e in
                    RowLine()
                    GridRow {
                        Text("\(e.count)").fontWeight(.semibold).foregroundStyle(Theme.bad)
                        HStack(spacing: 6) {
                            let look = Theme.tool(e.tool)
                            IconTile(symbol: look.symbol, color: look.color, size: 18)
                            Text(e.tool)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let cause = e.cause {
                                Text("Why: \(cause)").fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                            }
                            Text(e.message).lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .foregroundStyle(e.cause == nil ? .primary : .secondary)
                            if let ex = e.example {
                                Text("First: \(ex)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.dollars(e.costMicros)).fontWeight(.medium)
                    }
                    .font(rowFont)
                    .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Agents

/// Each agent: its cost, its context, and its cost on Sonnet.
struct LaneCosts: View {
    let anatomy: Anatomy

    var body: some View {
        let s = anatomy.spend
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Agents", note: "avg and max context: what one call of the agent read. On Sonnet: the same calls at Claude Sonnet 5.5 prices.")
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ColumnTitle("Agent").gridColumnAlignment(.leading)
                    ColumnTitle("Model").gridColumnAlignment(.leading)
                    ColumnTitle("Model calls")
                    ColumnTitle("Avg context")
                    ColumnTitle("Max context")
                    ColumnTitle("Cost")
                    ColumnTitle("On Sonnet")
                    ColumnTitle("")
                }
                ForEach(anatomy.lanesInTreeOrder) { l in
                    if let ls = s.lane(l.id) {
                        RowLine()
                        GridRow {
                            Text(l.name).lineLimit(1).help(l.name)
                                .padding(.leading, CGFloat(anatomy.depth(of: l)) * 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text((l.model ?? "").replacingOccurrences(of: "claude-", with: "")).foregroundStyle(.secondary)
                            Text("\(ls.modelCalls)")
                            Text(Format.tokens(ls.avgContext))
                            Text(Format.tokens(ls.maxContext))
                            Text(Format.dollars(ls.costMicros)).fontWeight(.medium)
                            Text(ls.sonnetCostMicros.map(Format.dollars) ?? "").foregroundStyle(Theme.ok)
                            ShareBar(share: s.share(ls.costMicros), color: Theme.agent)
                        }
                        .font(rowFont)
                        .monospacedDigit()
                    }
                }
            }
        }
    }
}
