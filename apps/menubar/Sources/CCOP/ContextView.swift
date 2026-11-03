import CCOPKit
import Charts
import SwiftUI

/// What filled the context window, call by call, and what added the most.
struct ContextView: View {
    let anatomy: Anatomy
    @State private var laneID = "main"
    @State private var selectedCall: Int?

    var body: some View {
        let lanes = anatomy.lanesInTreeOrder.filter { !$0.context.isEmpty }
        let lane = anatomy.lane(laneID) ?? lanes.first
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Context").font(.headline)
                    Picker("Lane", selection: $laneID) {
                        ForEach(lanes) { l in
                            Text("\(l.name) (\(l.context.count) calls)").tag(l.id)
                        }
                    }
                    .frame(maxWidth: 420)
                    Spacer()
                }
                Text("The size of the context at each model call is exact: the call's input tokens. The split into parts is estimated: the growth from one call to the next goes first to Claude's previous output, and the rest to the prompts and tool results that came between, by their size in bytes. “Start” is the first call: system prompt, tool definitions, instructions and the first prompt.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lane, !lane.context.isEmpty {
                    ContextChart(lane: lane, selectedCall: $selectedCall)
                    let index = min(max((selectedCall ?? lane.context.count) - 1, 0), lane.context.count - 1)
                    ContextBreakdown(lane: lane, point: lane.context[index], call: index + 1)
                } else {
                    Text("This session has no model calls with token counts.").foregroundStyle(.secondary)
                }
                Contributors(anatomy: anatomy)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: laneID) { selectedCall = nil }
    }
}

enum ContextColors {
    static func color(_ part: String) -> Color {
        switch part {
        case "Start": Color.gray
        case "Claude output": Color.indigo
        case "Prompts": Color.green
        case "Compacted summary": Color.red
        case "Other": Color.brown
        default:
            part.hasPrefix("Tool: ") ? Palette.tool(String(part.dropFirst(6))) : .secondary
        }
    }

    /// Part names in a stable order: Start, Compacted summary, Claude output,
    /// Prompts, then tools by their size at the end, then Other.
    static func order(_ points: [ContextPoint]) -> [String] {
        var last: [String: UInt64] = [:]
        for p in points { for part in p.parts { last[part.name] = max(last[part.name] ?? 0, part.tokens) } }
        let fixed = ["Start", "Compacted summary", "Claude output", "Prompts"]
        let tools = last.keys.filter { !fixed.contains($0) && $0 != "Other" }.sorted { (last[$0] ?? 0) > (last[$1] ?? 0) }
        return fixed.filter { last[$0] != nil } + tools + (last["Other"] != nil ? ["Other"] : [])
    }
}

struct ContextChart: View {
    let lane: AnatomyLane
    @Binding var selectedCall: Int?

    struct Mark: Identifiable {
        var call: Int
        var part: String
        var tokens: Double
        var id: String { "\(call) \(part)" }
    }

    /// At most ~400 calls drawn; every call is still in the breakdown.
    private var marks: [Mark] {
        let points = lane.context
        let names = ContextColors.order(points)
        let step = max(1, points.count / 400)
        var out: [Mark] = []
        for i in stride(from: 0, to: points.count, by: step) {
            let parts = Dictionary(points[i].parts.map { ($0.name, $0.tokens) }, uniquingKeysWith: +)
            for name in names { out.append(Mark(call: i + 1, part: name, tokens: Double(parts[name] ?? 0))) }
        }
        return out
    }

    var body: some View {
        let names = ContextColors.order(lane.context)
        let compactions = compactionCalls()
        Chart {
            ForEach(marks) { m in
                AreaMark(x: .value("Model call", m.call), y: .value("Tokens", m.tokens), stacking: .standard)
                    .foregroundStyle(by: .value("Part", m.part))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(compactions, id: \.self) { c in
                RuleMark(x: .value("Model call", c))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("compacted").font(.caption2).foregroundStyle(.red) }
            }
            if let c = selectedCall {
                RuleMark(x: .value("Model call", c)).foregroundStyle(.primary.opacity(0.5))
            }
        }
        .chartForegroundStyleScale(domain: names, range: names.map(ContextColors.color))
        .chartXSelection(value: $selectedCall)
        .chartXAxisLabel("Model call")
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Format.tokens(UInt64(max(0, d)))) } }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 300)
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

/// The parts of one call's context, largest first.
struct ContextBreakdown: View {
    let lane: AnatomyLane
    let point: ContextPoint
    let call: Int

    var body: some View {
        let parts = point.parts.sorted { $0.tokens > $1.tokens }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Call \(call) of \(lane.context.count)").font(.headline)
                Text("at \(point.at.formatted(date: .omitted, time: .standard)): \(Format.tokens(point.total)) tokens of context")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Click or drag on the chart to choose a call").font(.caption).foregroundStyle(.tertiary)
            }
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(parts, id: \.name) { p in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(ContextColors.color(p.name)).frame(width: 10, height: 10)
                            Text(p.name)
                        }
                        .gridColumnAlignment(.leading)
                        Text(Format.tokens(p.tokens)).monospacedDigit()
                        Text(Format.percent(point.total == 0 ? 0 : Double(p.tokens) / Double(point.total)))
                            .monospacedDigit().foregroundStyle(.secondary)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2).fill(ContextColors.color(p.name).opacity(0.7))
                                .frame(width: g.size.width * CGFloat(point.total == 0 ? 0 : Double(p.tokens) / Double(point.total)))
                        }
                        .frame(width: 220, height: 8)
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// The prompts and tool calls that added the most tokens to a context.
struct Contributors: View {
    let anatomy: Anatomy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Largest additions to the context").font(.headline)
            Text("Each one stays in the context of every later call of its lane until a compaction, so it is read again (from the cache) on each call.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(anatomy.contributors.enumerated()), id: \.offset) { _, c in
                    if let lane = anatomy.lane(c.lane), lane.events.indices.contains(c.event) {
                        let e = lane.events[c.event]
                        GridRow {
                            Text("+\(Format.tokens(c.tokens))").monospacedDigit().gridColumnAlignment(.trailing)
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(Palette.event(e)).frame(width: 8, height: 8)
                                Text(e.label)
                            }
                            Text(e.text ?? "").lineLimit(1).truncationMode(.middle).frame(maxWidth: 520, alignment: .leading)
                            Text(lane.name).lineLimit(1).foregroundStyle(.secondary)
                            Text(e.start.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.callout)
        }
    }
}
