import CCOPKit
import Charts
import SwiftUI

/// The soft background of the side panel.
private let panelBackground = Theme.dynamic(0xF7F7F8, 0x2A2A2D)

/// What filled the context window, call by call, and what added the most.
struct ContextView: View {
    let anatomy: Anatomy
    @State private var laneID = "main"
    @State private var selectedCall: Int?
    @State private var width: CGFloat = 1000

    /// Narrower than this, the side panel goes under the chart.
    private static let sideBySide: CGFloat = 760

    var body: some View {
        let lanes = anatomy.lanesInTreeOrder.filter { !$0.context.isEmpty }
        let lane = anatomy.lane(laneID) ?? lanes.first
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(lanes)
                if let lane, !lane.context.isEmpty {
                    let index = min(max((selectedCall ?? lane.context.count) - 1, 0), lane.context.count - 1)
                    let wide = width >= Self.sideBySide
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                    layout {
                        ContextChart(lane: lane, selectedCall: $selectedCall, shownCall: index + 1)
                            .frame(maxWidth: .infinity)
                        ContextBreakdown(lane: lane, point: lane.context[index], call: index + 1)
                            .frame(width: wide ? 270 : nil)
                            .frame(maxWidth: wide ? nil : .infinity)
                    }
                } else {
                    Text("This session has no model calls with token counts.").foregroundStyle(.secondary)
                }
                Contributors(anatomy: anatomy)
                    .frame(maxWidth: 900, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .onChange(of: laneID) { selectedCall = nil }
    }

    private func header(_ lanes: [AnatomyLane]) -> some View {
        HStack(spacing: 14) {
            Text("Context at each model call").font(.system(size: 13, weight: .semibold))
            Picker("Lane", selection: $laneID) {
                ForEach(lanes) { l in
                    Text("\(l.name) · \(l.context.count) \(l.context.count == 1 ? "call" : "calls")").tag(l.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            Text("The size is exact. The split into parts is estimated.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1)
                .help("The size of the context at each model call is exact: the call's input tokens. The split into parts is estimated: the growth from one call to the next goes first to Claude's previous output, and the rest to the prompts and tool results that came between, by their size in bytes. “Start” is the first call: system prompt, tool definitions, instructions and the first prompt.")
            Spacer(minLength: 0)
        }
    }
}

/// Names and colors of the context parts. A tool part is drawn in the series
/// of its tool family, so the chart has one area per color.
enum ContextColors {
    static let start = Theme.dynamic(0xB4B4BA, 0x636366)
    static let summary = Theme.dynamic(0x57575C, 0xA1A1A8)
    static let other = Theme.dynamic(0xA8A29E, 0x78716C)

    /// The series of a part, as `context.rs` names parts.
    static func series(_ part: String) -> String {
        guard part.hasPrefix("Tool: ") else { return part }
        // The same families as `Theme.tool`.
        switch String(part.dropFirst(6)) {
        case "Bash", "BashOutput", "KillShell": return "Bash"
        case "Read", "NotebookRead": return "Read"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Edit and Write"
        case "Grep", "Glob", "LS": return "Search"
        case "Agent", "Task": return "Subagents"
        case "WebFetch", "WebSearch": return "Web"
        default: return "Other tools"
        }
    }

    static func color(series: String) -> Color {
        switch series {
        case "Start": start
        case "Compacted summary": summary
        case "Claude output": Theme.output
        case "Prompts": Theme.prompt
        case "Other": other
        case "Bash": Theme.bash
        case "Read": Theme.read
        case "Edit and Write": Theme.edit
        case "Search": Theme.grep
        // Lighter, so it differs from "Claude output", which has the same hue.
        case "Subagents": Theme.agent.opacity(0.5)
        case "Web": Theme.web
        default: Theme.otherTool
        }
    }

    static func color(_ part: String) -> Color { color(series: series(part)) }

    /// A part or series name as shown: `Tool: Bash` → `Bash`, `Prompts` → `Your prompts` in the main lane.
    static func label(_ name: String, main: Bool) -> String {
        if name.hasPrefix("Tool: ") { return String(name.dropFirst(6)) }
        if name == "Prompts", main { return "Your prompts" }
        return name
    }

    /// Series in a stable order: Start, Compacted summary, Claude output,
    /// Prompts, then tool families by their largest size, then Other.
    static func order(_ points: [ContextPoint]) -> [String] {
        var largest: [String: UInt64] = [:]
        for p in points {
            var sums: [String: UInt64] = [:]
            for part in p.parts { sums[series(part.name), default: 0] += part.tokens }
            for (s, n) in sums { largest[s] = max(largest[s] ?? 0, n) }
        }
        let fixed = ["Start", "Compacted summary", "Claude output", "Prompts"]
        let tools = largest.keys.filter { !fixed.contains($0) && $0 != "Other" }
            .sorted { (largest[$0] ?? 0, $1) > (largest[$1] ?? 0, $0) }
        return fixed.filter { largest[$0] != nil } + tools + (largest["Other"] != nil ? ["Other"] : [])
    }
}

struct ContextChart: View {
    let lane: AnatomyLane
    @Binding var selectedCall: Int?
    /// The call shown in the side panel: the selected one, or the last.
    let shownCall: Int

    struct Mark: Identifiable {
        var call: Int
        var series: String
        var tokens: Double
        var id: String { "\(call) \(series)" }
    }

    /// At most ~400 calls drawn; every call is still in the side panel.
    private func marks(_ names: [String]) -> [Mark] {
        let points = lane.context
        let step = max(1, points.count / 400)
        var out: [Mark] = []
        for i in stride(from: 0, to: points.count, by: step) {
            var sums: [String: UInt64] = [:]
            for part in points[i].parts { sums[ContextColors.series(part.name), default: 0] += part.tokens }
            for name in names { out.append(Mark(call: i + 1, series: name, tokens: Double(sums[name] ?? 0))) }
        }
        return out
    }

    var body: some View {
        let names = ContextColors.order(lane.context)
        let count = lane.context.count
        let compactions = compactionCalls()
        let shown = lane.context[min(max(shownCall, 1), count) - 1]
        let labels = Array(Set([1, (count + 1) / 2, count])).sorted()
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(marks(names)) { m in
                    AreaMark(x: .value("Model call", m.call), y: .value("Tokens", m.tokens), stacking: .standard)
                        .foregroundStyle(by: .value("Part", m.series))
                        .interpolationMethod(.stepEnd)
                }
                ForEach(compactions, id: \.self) { c in
                    RuleMark(x: .value("Model call", c))
                        .foregroundStyle(Theme.bad)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, alignment: .center, spacing: 3,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("compacted").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.bad)
                        }
                }
                RuleMark(x: .value("Model call", shownCall))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Model call", shownCall), y: .value("Tokens", Double(shown.total)))
                    .symbol {
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: 2))
                            .frame(width: 9, height: 9)
                    }
            }
            .chartForegroundStyleScale(domain: names, range: names.map { ContextColors.color(series: $0) })
            .chartLegend(.hidden)
            .chartXSelection(value: $selectedCall)
            .chartXScale(domain: 1 ... max(count, 2))
            .chartXAxis {
                AxisMarks(values: labels) { v in
                    if let c = v.as(Int.self), (1 ... count).contains(c) {
                        AxisValueLabel(anchor: c == 1 && count > 1 ? .topLeading : c == count && count > 1 ? .topTrailing : .top) {
                            Text("call \(c) · \(lane.context[c - 1].at.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(Format.tokens(UInt64(max(0, d)))).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 300)
            .padding(.top, compactions.isEmpty ? 0 : 16)
            .accessibilityLabel("Stacked area chart of the context at each of \(count) model calls")

            ContextLegendFlow(spacing: 14, lineSpacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(ContextColors.color(series: name)).frame(width: 9, height: 9)
                        Text(ContextColors.label(name, main: lane.id == "main"))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The calls right after a compaction.
    private func compactionCalls() -> [Int] {
        var out: [Int] = []
        for (n, p) in lane.context.enumerated() where n > 0 {
            let before = lane.context[n - 1].event
            if lane.events[before ..< p.event].contains(where: { $0.kind == .compact }) { out.append(n + 1) }
        }
        return out
    }
}

/// The parts of one call's context, largest first, on a side panel.
struct ContextBreakdown: View {
    let lane: AnatomyLane
    let point: ContextPoint
    let call: Int

    /// Rows shown; the smaller parts are summed in one row.
    static let shownParts = 10

    var body: some View {
        let sorted = point.parts.sorted { $0.tokens > $1.tokens }
        let parts = sorted.prefix(Self.shownParts)
        let rest = sorted.dropFirst(Self.shownParts)
        let shape = RoundedRectangle(cornerRadius: 10)
        VStack(alignment: .leading, spacing: 8) {
            Text("Call \(call) of \(lane.context.count) · \(point.at.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Format.tokens(point.total)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Text("tokens of context").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(parts, id: \.name) { p in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(ContextColors.color(p.name)).frame(width: 10, height: 10)
                        Text(ContextColors.label(p.name, main: lane.id == "main")).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Format.tokens(p.tokens)).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .help("\(Format.percent(point.total == 0 ? 0 : Double(p.tokens) / Double(point.total))) of this call's context")
                }
                if !rest.isEmpty {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 10, height: 10)
                        Text("\(rest.count) smaller parts").foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(Format.tokens(rest.reduce(0) { $0 + $1.tokens })).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .help(rest.map { "\(ContextColors.label($0.name, main: lane.id == "main")): \(Format.tokens($0.tokens))" }.joined(separator: "\n"))
                }
            }
            .padding(.top, 4)
            Text("Click or drag on the chart to choose a call.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: shape)
        .overlay(shape.stroke(Color.primary.opacity(0.1)))
    }
}

/// The prompts and tool calls that added the most tokens to a context.
struct Contributors: View {
    let anatomy: Anatomy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Largest additions to the context").font(.system(size: 13, weight: .semibold))
            Text("Each one stays in every later call of its lane until a compaction, so it is read again on each call.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(Array(anatomy.contributors.enumerated()), id: \.offset) { _, c in
                    if let lane = anatomy.lane(c.lane), lane.events.indices.contains(c.event) {
                        let e = lane.events[c.event]
                        Divider()
                        GridRow {
                            Text("+\(Format.tokens(c.tokens))").fontWeight(.semibold)
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(color(e)).frame(width: 8, height: 8)
                                Text(e.label).lineLimit(1)
                            }
                            Text(e.command ?? e.text ?? "")
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(where_(lane, c.event))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .gridColumnAlignment(.trailing)
                        }
                        .padding(.vertical, 7)
                        .help("\(lane.name) · \(e.start.formatted(date: .omitted, time: .standard))")
                    }
                }
            }
            .font(.system(size: 12.5))
            .monospacedDigit()
            .padding(.top, 4)
        }
    }

    private func color(_ e: AnatomyEvent) -> Color {
        switch e.kind {
        case .tool: ContextColors.color("Tool: \(e.tool ?? "")")
        case .prompt: Theme.prompt
        case .compact: ContextColors.summary
        case .answer: Theme.output
        case .error: Theme.bad
        }
    }

    /// `call 41 · read 57 more times`, with the lane's name when it is a subagent.
    private func where_(_ lane: AnatomyLane, _ event: Int) -> String {
        var parts: [String] = []
        if lane.id != "main" { parts.append(lane.name) }
        if let calls = lane.readingCalls(after: event) {
            parts.append("call \(calls.lowerBound + 1)")
            let more = calls.count - 1
            if more > 0 { parts.append("read \(more) more \(more == 1 ? "time" : "times")") }
        }
        return parts.joined(separator: " · ")
    }
}

/// Lays its children out in rows, wrapping to a new row when one is full.
private struct ContextLegendFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
