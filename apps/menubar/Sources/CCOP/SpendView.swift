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
                PromptCosts(anatomy: anatomy)
                CauseTable(spend: s)
                if !s.commands.isEmpty { CommandTable(session: session, anatomy: anatomy) }
                if !s.errors.isEmpty { ErrorTable(spend: s) }
                if anatomy.lanes.count > 1 { LaneCosts(anatomy: anatomy) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ s: Spend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat(Format.dollars(s.costMicros), "API-equivalent cost")
                if let budget = model.plan.weeklyBudgetMicros, budget > 0 {
                    stat(Format.percent(Double(s.costMicros) / Double(budget)), "of your weekly limit")
                }
                stat(Format.tokens(s.tokens), "tokens")
                stat("\(s.lanes.reduce(0) { $0 + $1.modelCalls })", "model calls")
            }
            Text("Every model call reads the whole context again, so a session costs about: model calls × context size. Below, the cost of each call goes to what made the model run: a tool result, your message, or the task a subagent got. Cost is at API prices, so a cheap cache read weighs less than an output token.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A part of the whole, as a short bar.
struct ShareBar: View {
    let share: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, share))))
            }
        }
        .frame(width: 90, height: 6)
    }
}

struct TipList: View {
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to change").font(.headline)
            if spend.tips.isEmpty {
                Text("ccop found nothing large to change in this session.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(spend.tips) { tip in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(tip.kind)).foregroundStyle(.orange).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tip.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(tip.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        if let saving = tip.savingMicros {
                            Text("save up to \(Format.dollars(saving))").font(.callout.weight(.semibold)).foregroundStyle(.green)
                            Text("\(Format.percent(spend.share(saving))) of the session").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(Format.dollars(tip.costMicros)).font(.callout.weight(.semibold))
                            Text("\(Format.percent(spend.share(tip.costMicros))) of the session").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            }
        }
    }

    private func icon(_ kind: TipKind) -> String {
        switch kind {
        case .manyCalls: "arrow.triangle.2.circlepath"
        case .errors: "exclamationmark.triangle"
        case .model: "cpu"
        case .bigContext: "square.stack.3d.up"
        case .bigResults: "doc.text.magnifyingglass"
        case .cacheRewrites: "clock.arrow.circlepath"
        }
    }
}

/// Each of your prompts and what its turn cost, with the subagents it started.
struct PromptCosts: View {
    let anatomy: Anatomy

    var body: some View {
        let s = anatomy.spend
        VStack(alignment: .leading, spacing: 6) {
            Text("Your messages").font(.headline)
            Text("What each message cost: the main session's calls until your next message, and the subagents started in that time.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("#")
                    Text("Time")
                    Text("Message").gridColumnAlignment(.leading)
                    Text("Main")
                    Text("Subagents")
                    Text("Total")
                    Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(anatomy.turns) { t in
                    GridRow {
                        Text(t.index > 0 ? "\(t.index)" : "")
                        Text(t.start.formatted(date: .omitted, time: .shortened))
                        Text(t.prompt).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(t.prompt)
                        Text(Format.dollars(t.costMicros))
                        Text(t.subagents.isEmpty ? "" : "\(Format.dollars(t.subagentCostMicros)) in \(t.subagents.count)")
                        Text(Format.dollars(t.totalCostMicros)).fontWeight(.semibold)
                        ShareBar(share: s.share(t.totalCostMicros))
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }
}

/// What made the model run, the most cost first.
struct CauseTable: View {
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What made the model run").font(.headline)
            Text("After a tool result the model runs again and reads the whole context. A call after several results counts a part for each. Context added: tokens the results put into the context (estimated).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Cause").gridColumnAlignment(.leading)
                    Text("Count")
                    Text("Errors")
                    Text("Model calls")
                    Text("Avg context")
                    Text("Context added")
                    Text("Cost")
                    Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(spend.causes.filter { $0.costMicros > 0 || $0.count > 0 }) { c in
                    GridRow {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(color(c)).frame(width: 8, height: 8)
                            Text(c.name).lineLimit(1)
                        }
                        Text(c.count > 0 ? "\(c.count)" : "")
                        Text(c.errors > 0 ? "\(c.errors)" : "").foregroundStyle(.red)
                        Text("\(Int(c.modelCalls.rounded()))")
                        Text(c.avgContext > 0 ? Format.tokens(c.avgContext) : "")
                        Text(c.addedTokens > 0 ? Format.tokens(c.addedTokens) : "")
                        Text(Format.dollars(c.costMicros)).fontWeight(.semibold)
                        HStack(spacing: 6) {
                            ShareBar(share: spend.share(c.costMicros), color: color(c))
                            Text(Format.percent(spend.share(c.costMicros))).font(.caption).frame(width: 36, alignment: .trailing)
                        }
                    }
                    .monospacedDigit()
                    .help(help(c))
                }
            }
            .font(.callout)
        }
    }

    private func color(_ c: Cause) -> Color {
        switch c.kind {
        case .tool: Palette.tool(c.name)
        case .prompt, .task: Palette.prompt
        case .compact: Palette.compact
        case .other: Color.secondary
        }
    }

    private func help(_ c: Cause) -> String {
        switch c.kind {
        case .prompt: "Model calls right after one of your messages."
        case .task: "The first call of a subagent, after the task its lead gave it."
        case .compact: "Model calls right after a compaction."
        case .other: "Model calls with nothing new before them in their lane."
        case .tool:
            c.errorCostMicros > 0
                ? "\(Format.dollars(c.errorCostMicros)) of it came after failed calls."
                : "Model calls after \(c.name) results."
        }
    }
}

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
        VStack(alignment: .leading, spacing: 6) {
            Text("Bash commands").font(.headline)
            Text("Bash calls by the program they ran (after `cd <folder> &&`). Cost: the model calls after their results. Click a program to see each call; click a call to see its whole input and output.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Program").gridColumnAlignment(.leading)
                    Text("Calls")
                    Text("Errors")
                    Text("Avg output")
                    Text("Cost")
                    Text("")
                    Text("Example").gridColumnAlignment(.leading)
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(shown) { g in
                    let isOpen = open.contains(g.group)
                    GridRow {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").font(.caption2).rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(.secondary)
                            Text(g.group).lineLimit(1).font(.callout.monospaced())
                        }
                        Text("\(g.calls)")
                        Text(g.errors > 0 ? "\(g.errors)" : "").foregroundStyle(.red)
                        Text(Format.bytes(g.calls == 0 ? 0 : g.resultBytes / g.calls))
                        Text(Format.dollars(g.costMicros)).fontWeight(.semibold)
                        HStack(spacing: 6) {
                            ShareBar(share: spend.share(g.costMicros), color: Palette.tool("Bash"))
                            Text(Format.percent(spend.share(g.costMicros))).font(.caption).frame(width: 36, alignment: .trailing)
                        }
                        Text(g.example ?? "").foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(g.example ?? "")
                    }
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isOpen { open.remove(g.group) } else { open.insert(g.group) }
                    }
                    if isOpen {
                        GridRow {
                            CallList(anatomy: anatomy, items: g.items, shownCall: $shownCall)
                                .gridCellColumns(7)
                        }
                    }
                }
            }
            .font(.callout)
            if spend.commands.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(spend.commands.count)") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .sheet(item: $shownCall) { ref in
            if let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                CallSheet(sessionID: session.id, lane: lane, index: ref.index)
            }
        }
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
        VStack(alignment: .leading, spacing: 2) {
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
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Time")
                    Text("Agent").gridColumnAlignment(.leading)
                    Text("Command").gridColumnAlignment(.leading)
                    Text("Output")
                    Text("Added")
                    Text("Cost")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(rows, id: \.self) { item in
                    if let lane = anatomy.lane(item.lane), lane.events.indices.contains(item.event) {
                        let e = lane.events[item.event]
                        GridRow {
                            Text(e.start.formatted(date: .omitted, time: .standard))
                            Text(lane.name).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                            Text(e.command ?? e.text ?? "").font(.caption.monospaced()).lineLimit(1)
                                .foregroundStyle(e.isError ? .red : .primary)
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
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }
}

/// Failed tool calls, grouped by the start of their error text.
struct ErrorTable: View {
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Errors").font(.headline)
            Text("Failed tool calls whose error text starts the same way. Cost: the model calls after them, which usually try again.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .topTrailing, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Times")
                    Text("Tool").gridColumnAlignment(.leading)
                    Text("Error").gridColumnAlignment(.leading)
                    Text("Cost")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(spend.errors) { e in
                    GridRow {
                        Text("\(e.count)").fontWeight(.semibold).foregroundStyle(.red)
                        Text(e.tool)
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
                        Text(Format.dollars(e.costMicros))
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }
}

/// Each agent: its cost, its context, and its cost on Sonnet.
struct LaneCosts: View {
    let anatomy: Anatomy

    var body: some View {
        let s = anatomy.spend
        VStack(alignment: .leading, spacing: 6) {
            Text("Agents").font(.headline)
            Text("Avg and max context: what one call of the agent read. On Sonnet: the same calls at Claude Sonnet 5.5 prices, for agents on a model that costs more.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Agent").gridColumnAlignment(.leading)
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Model calls")
                    Text("Avg context")
                    Text("Max context")
                    Text("Cost")
                    Text("On Sonnet")
                    Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(anatomy.lanesInTreeOrder) { l in
                    if let ls = s.lane(l.id) {
                        GridRow {
                            Text(l.name).lineLimit(1).help(l.name)
                                .padding(.leading, CGFloat(anatomy.depth(of: l)) * 12)
                            Text((l.model ?? "").replacingOccurrences(of: "claude-", with: "")).foregroundStyle(.secondary)
                            Text("\(ls.modelCalls)")
                            Text(Format.tokens(ls.avgContext))
                            Text(Format.tokens(ls.maxContext))
                            Text(Format.dollars(ls.costMicros)).fontWeight(.semibold)
                            Text(ls.sonnetCostMicros.map(Format.dollars) ?? "").foregroundStyle(.green)
                            ShareBar(share: s.share(ls.costMicros))
                        }
                        .monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }
}
