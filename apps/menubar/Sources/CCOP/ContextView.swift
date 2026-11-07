import AppKit
import CCOPKit
import Charts
import SwiftUI

/// The colours of the design board (WindowContext), local to this tab.
private enum Ink {
    /// `--text`
    static let text = Theme.dynamic(0x1D1D1F, 0xF5F5F7)
    /// `--text2`
    static let text2 = Theme.dynamic(0x5F5F64, 0xB9B9BF)
    /// `--text3`
    static let text3 = Theme.dynamic(0x6E6E73, 0xA1A1A8)
    /// `--line`: rgba(0,0,0,.10)
    static let line = alpha(0.10, 0.14)
    /// `--line2`: rgba(0,0,0,.06)
    static let line2 = alpha(0.06, 0.09)
    /// `--soft`
    static let soft = Theme.dynamic(0xF7F7F8, 0x2A2A2D)
    /// `--bg`
    static let bg = Theme.page

    /// Black with `light` alpha in light mode, white with `dark` alpha in dark mode.
    static func alpha(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        })
    }
}

/// What filled the context window, call by call, and what added the most.
struct ContextView: View {
    let session: Session
    let anatomy: Anatomy
    @State private var laneID = "main"
    /// The call under the pointer and the call chosen with a click. With
    /// neither, the last call shows.
    @State private var pick = ChartPick()
    @State private var width: CGFloat = 1000

    /// The chart column's and the side panel's flex basis, and the gap between
    /// them. Narrower than their sum, the side panel goes under the chart.
    private static let chartBasis: CGFloat = 460
    /// 240 of content + 2 × 14 padding + 2 × 1 border (the board's aside is content-box).
    private static let asideBasis: CGFloat = 270
    private static let gap: CGFloat = 20

    var body: some View {
        let lanes = anatomy.lanesInTreeOrder.filter { !$0.context.isEmpty }
        let lane = anatomy.lane(laneID).flatMap { $0.context.isEmpty ? nil : $0 } ?? lanes.first
        PageScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TokenTimeline(anatomy: anatomy)
                header(lanes, current: lane)
                if let lane, !lane.context.isEmpty {
                    let index = min(max(pick.shown(or: lane.context.count) - 1, 0), lane.context.count - 1)
                    let free = width - Self.chartBasis - Self.gap - Self.asideBasis
                    let wide = free >= 0
                    // As `flex: 999 1 460px` beside `flex: 1 1 240px`: the panel gets 1/1000 of the free width.
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: Self.gap))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.gap))
                    layout {
                        ContextChart(lane: lane, pick: $pick, shownCall: index + 1)
                            .frame(maxWidth: .infinity)
                        ContextBreakdown(lane: lane, point: lane.context[index], call: index + 1, pinned: pick.pinned != nil)
                            .frame(width: wide ? Self.asideBasis + free / 1000 : nil)
                            .frame(maxWidth: wide ? nil : .infinity)
                    }
                    ContextHoldings(sessionID: anatomy.sessionId, dir: session.projectDir, lane: lane, call: index)
                        .frame(maxWidth: 900, alignment: .leading)
                } else {
                    Text("This session has no model calls with token counts.")
                        .font(.system(size: 13)).foregroundStyle(Ink.text3)
                }
                Contributors(anatomy: anatomy)
                    .frame(maxWidth: 900, alignment: .leading)
            }
            .foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .onChange(of: laneID) { pick = ChartPick() }
    }

    private func header(_ lanes: [AnatomyLane], current: AnatomyLane?) -> some View {
        FlowRows(spacing: 14, lineSpacing: 10) {
            Text("Context at each model call").font(.system(size: 13, weight: .semibold))
            if !lanes.isEmpty {
                LanePicker(lanes: lanes, current: current, selection: $laneID)
            }
            Text("The size is exact. The split into parts is estimated.")
                .font(.system(size: 12)).foregroundStyle(Ink.text3)
                .help("The size of the context at each model call is exact: the call's input tokens. The split into parts is estimated: the growth from one call to the next goes first to Claude's previous output, and the rest to the prompts and tool results that came between, by their size in bytes. “Start” is the first call: system prompt, tool definitions, instructions and the first prompt.")
        }
    }
}

/// The series of the chart, their colours and names. A tool part is drawn in
/// the series of its tool family, so the chart has one area per colour.
enum ContextColors {
    /// Bottom to top of the stack.
    static let stack = ["Start", "Compacted summary", "Claude output", "Prompts", "Read", "Bash", "Edit", "Other tools", "Other"]

    static let start = Theme.dynamic(0xB4B4BA, 0x6C6C72)
    static let summary = Theme.dynamic(0x57575C, 0xA1A1A8)
    static let output = Theme.dynamic(0x8B5CF6, 0xA78BFA)
    static let prompts = Theme.dynamic(0x22A35A, 0x3CCB7F)
    static let read = Theme.dynamic(0xD9A21B, 0xE8B83A)
    static let bash = Theme.dynamic(0x14A89A, 0x2DD4BF)
    static let edit = Theme.dynamic(0xE0559A, 0xF472B6)
    static let otherTools = Theme.dynamic(0x6D67E8, 0x8D88F2)
    /// Growth with no prompt or tool result before it (`context.rs`: `Other`).
    static let other = Theme.dynamic(0xA8A29E, 0x78716C)

    /// The series of a part, as `context.rs` names parts.
    static func series(_ part: String) -> String {
        guard part.hasPrefix("Tool: ") else { return stack.contains(part) ? part : "Other" }
        switch String(part.dropFirst(6)) {
        case "Read", "NotebookRead": return "Read"
        case "Bash", "BashOutput", "KillShell": return "Bash"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Edit"
        default: return "Other tools"
        }
    }

    static func color(series: String) -> Color {
        switch series {
        case "Start": start
        case "Compacted summary": summary
        case "Claude output": output
        case "Prompts": prompts
        case "Read": read
        case "Bash": bash
        case "Edit": edit
        case "Other tools": otherTools
        default: other
        }
    }

    static func color(_ part: String) -> Color { color(series: series(part)) }

    /// A series or part name as shown: `Prompts` → `Your prompts` in the main lane, `Tool: Grep` → `Grep`.
    static func label(_ name: String, main: Bool) -> String {
        if name.hasPrefix("Tool: ") { return String(name.dropFirst(6)) }
        if name == "Prompts" { return main ? "Your prompts" : "Prompts" }
        return name
    }

    /// The tokens of one call by series.
    static func sums(_ point: ContextPoint) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for part in point.parts { out[series(part.name), default: 0] += part.tokens }
        return out
    }

    /// The series that some call of the lane has, bottom to top.
    static func present(_ points: [ContextPoint]) -> [String] {
        var seen = Set<String>()
        for p in points { for part in p.parts where part.tokens > 0 { seen.insert(series(part.name)) } }
        return stack.filter(seen.contains)
    }
}

/// `Main · 168 calls`, with a chevron, as the board's button; a click opens a menu of the lanes.
private struct LanePicker: View {
    let lanes: [AnatomyLane]
    let current: AnatomyLane?
    @Binding var selection: String
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(current.map(Self.title) ?? "")
                Chevron()
                    .stroke(style: StrokeStyle(lineWidth: 1.125, lineCap: .round, lineJoin: .round))
                    .frame(width: 9, height: 9)
            }
            .font(.system(size: 12))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Ink.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .accessibilityLabel("Lane: \(current.map(Self.title) ?? "")")
        .help("Choose the main session or a subagent")
    }

    static func title(_ lane: AnatomyLane) -> String {
        let name = lane.id == "main" ? "Main" : lane.name
        let n = lane.context.count
        return "\(name) · \(n) \(n == 1 ? "call" : "calls")"
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let binding = $selection
        let target = MenuTarget { binding.wrappedValue = $0 }
        let menu = NSMenu()
        for lane in lanes {
            let item = NSMenuItem(title: Self.title(lane), action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = lane.id
            item.state = lane.id == current?.id ? .on : .off
            menu.addItem(item)
        }
        // The menu's top-left corner 4 pt under the button.
        let y = view.isFlipped ? view.bounds.height + 4 : -4
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
        }
    }
}

/// The board's chevron: `M4 6l4 4 4-4` in a 16 × 16 box.
private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 16
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 4 * s, y: rect.minY + 6 * s))
        p.addLine(to: CGPoint(x: rect.minX + 8 * s, y: rect.minY + 10 * s))
        p.addLine(to: CGPoint(x: rect.minX + 12 * s, y: rect.minY + 6 * s))
        return p
    }
}

private final class MenuAnchor {
    weak var view: NSView?
}

/// An empty AppKit view behind the button, so the menu can open at it.
private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

private final class MenuTarget: NSObject {
    let action: (String) -> Void
    init(_ action: @escaping (String) -> Void) { self.action = action }
    @objc func pick(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { action(id) }
    }
}

struct ContextChart: View {
    let lane: AnatomyLane
    @Binding var pick: ChartPick
    /// The call shown in the side panel: the chosen one, or the last.
    let shownCall: Int

    private static let height: CGFloat = 300
    /// The room for the y labels left of the plot.
    private static let gutter: CGFloat = 40
    /// Grid lines above the base line; the top one is the top of the plot.
    private static let lines = 4

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
            let sums = ContextColors.sums(points[i])
            for name in names { out.append(Mark(call: i + 1, series: name, tokens: Double(sums[name] ?? 0))) }
        }
        return out
    }

    /// A round step, so that `lines` steps hold the largest context: 148K → 40K (top 160K).
    static func gridStep(for largest: UInt64) -> UInt64 {
        let raw = max(Double(largest), 1000) / Double(lines)
        let magnitude = pow(10, floor(log10(raw)))
        let factor = [1, 2, 2.5, 4, 5, 10].first { $0 * magnitude >= raw } ?? 10
        return UInt64((factor * magnitude).rounded())
    }

    var body: some View {
        let names = ContextColors.present(lane.context)
        let count = lane.context.count
        let compactions = compactionCalls()
        let shownIndex = min(max(shownCall, 1), count) - 1
        let step = Self.gridStep(for: lane.context.map(\.total).max() ?? 0)
        let top = Double(step) * Double(Self.lines)
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                grid(step)
                Chart {
                    ForEach(marks(names)) { m in
                        AreaMark(x: .value("Model call", m.call), y: .value("Tokens", m.tokens), stacking: .standard)
                            .foregroundStyle(by: .value("Part", m.series))
                            .interpolationMethod(.linear)
                    }
                }
                .chartForegroundStyleScale(domain: names, range: names.map { ContextColors.color(series: $0) })
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: 1 ... max(count, 2))
                .chartYScale(domain: 0 ... top)
                .chartOverlay { proxy in
                    ZStack {
                        GeometryReader { geo in
                            if let plot = proxy.plotFrame.map({ geo[$0] }) {
                                let xs = compactions.compactMap { proxy.position(forX: $0).map { plot.minX + $0 } }
                                ForEach(Array(Self.labelled(xs).enumerated()), id: \.offset) { _, mark in
                                    compactionMark(x: mark.x, labelled: mark.labelled, plot: plot)
                                }
                                if let x = proxy.position(forX: shownIndex + 1),
                                   let y = proxy.position(forY: Double(lane.context[shownIndex].total)) {
                                    selectionMark(x: plot.minX + x, y: plot.minY + y, plot: plot)
                                }
                            }
                        }
                        .allowsHitTesting(false)
                        ChartPicker(proxy: proxy, pick: $pick) { x in
                            proxy.value(atX: x, as: Int.self).map { min(max($0, 1), count) }
                        }
                    }
                }
                .padding(.leading, Self.gutter)
            }
            .frame(height: Self.height)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Stacked area chart of the context at each of \(count) model calls")

            xLabels(count)
                .padding(.leading, Self.gutter)

            FlowRows(spacing: 14, lineSpacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(ContextColors.color(series: name)).frame(width: 9, height: 9)
                        Text(ContextColors.label(name, main: lane.id == "main"))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.text2)
                }
            }
            .padding(.leading, Self.gutter)
        }
    }

    /// Horizontal lines from the left edge of the labels to the right of the
    /// plot, with the label on each line, as the board draws them.
    private func grid(_ step: UInt64) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(1 ... Self.lines, id: \.self) { k in
                let y = Self.height - Self.height * CGFloat(k) / CGFloat(Self.lines)
                Rectangle().fill(Ink.line2).frame(height: 1).frame(maxWidth: .infinity).offset(y: y)
                Text(Format.tokens(step * UInt64(k)))
                    .font(.system(size: 10.5)).monospacedDigit()
                    .foregroundStyle(Ink.text3)
                    .offset(y: y - 7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// A 2 pt red line from 4 pt above the plot to its bottom, `compacted` 20 pt above.
    private func compactionMark(x: CGFloat, labelled: Bool, plot: CGRect) -> some View {
        ZStack {
            Rectangle().fill(Theme.bad)
                .frame(width: 2, height: plot.height + 4)
                .position(x: x + 1, y: (plot.minY - 4 + plot.maxY) / 2)
            if labelled {
                Text("compacted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.bad)
                    .fixedSize()
                    .position(x: min(max(x, plot.minX - Self.gutter + 30), plot.maxX - 30), y: plot.minY - 20 + 6.5)
            }
        }
    }

    /// Compaction lines, left to right; a line gets the `compacted` label only
    /// when it is far enough from the last labelled one, so labels do not overlap.
    static func labelled(_ xs: [CGFloat]) -> [(x: CGFloat, labelled: Bool)] {
        var last = -CGFloat.infinity
        return xs.sorted().map { x in
            let show = x - last >= 70
            if show { last = x }
            return (x, show)
        }
    }

    /// A 1 pt line over the chosen call and a ring on the top of its stack.
    private func selectionMark(x: CGFloat, y: CGFloat, plot: CGRect) -> some View {
        ZStack {
            Rectangle().fill(Ink.text)
                .frame(width: 1, height: plot.height)
                .position(x: x + 0.5, y: plot.midY)
            Circle().fill(Ink.bg)
                .overlay(Circle().strokeBorder(Ink.text, lineWidth: 2))
                .frame(width: 9, height: 9)
                .position(x: x + 0.5, y: y)
        }
    }

    /// `call 1 · 09:12`, the middle call and the last, spread as `justify-content: space-between`.
    private func xLabels(_ count: Int) -> some View {
        let calls = Array(Set([1, (count + 1) / 2, count])).sorted()
        return HStack(spacing: 0) {
            ForEach(Array(calls.enumerated()), id: \.element) { n, c in
                if n > 0 { Spacer(minLength: 8) }
                Text("call \(c) · \(lane.context[c - 1].at.formatted(date: .omitted, time: .shortened))")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(Ink.text3)
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

/// The parts of one call's context, top of the stack first, on a side panel.
struct ContextBreakdown: View {
    @Environment(AppModel.self) private var model
    let lane: AnatomyLane
    let point: ContextPoint
    let call: Int
    /// The call was chosen with a click, so it stays when the pointer leaves.
    let pinned: Bool

    var body: some View {
        let main = lane.id == "main"
        let sums = ContextColors.sums(point)
        // Every part of the lane, also at 0, so the panel and the page below
        // it keep their place from call to call.
        let present = ContextColors.present(lane.context)
        let rows = ContextColors.stack.reversed().filter { present.contains($0) }
        let shape = RoundedRectangle(cornerRadius: 10)
        VStack(alignment: .leading, spacing: 8) {
            Text("Call \(call) of \(lane.context.count) · \(point.at.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Ink.text3)
            (Text("\(Format.tokens(point.total)) ").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.text)
                + Text("tokens of context").font(.system(size: 13)).foregroundStyle(Ink.text2))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows, id: \.self) { series in
                    let tokens = sums[series] ?? 0
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(ContextColors.color(series: series)).frame(width: 10, height: 10)
                        Text(ContextColors.label(series, main: main))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.tokens(tokens))
                            .lineLimit(1)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .help(help(series, tokens, main: main))
                }
            }
            .padding(.top, 4)
            Button("Go to Chat") { model.openInChat(ChatPlace(lane: lane.id, event: point.event)) }
                .controlSize(.small)
                .help("Show this model call in the Chat tab")
                .padding(.top, 2)
            Text(pinned ? "This call stays here. Click another call to change it, or this call to let it go."
                : "Click or drag on the chart to keep a call here.")
                .font(.system(size: 11))
                .foregroundStyle(Ink.text3)
                .lineSpacing(2.4)
                .padding(.vertical, 1.2)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        // The board's aside: 14 pt padding inside a 1 pt border.
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.soft, in: shape)
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
    }

    /// The share of the call, and the parts in a series of several (`Other tools`).
    private func help(_ series: String, _ tokens: UInt64, main: Bool) -> String {
        let share = Format.percent(point.total == 0 ? 0 : Double(tokens) / Double(point.total))
        let parts = point.parts.filter { ContextColors.series($0.name) == series && $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
        var lines = ["\(share) of this call's context"]
        if parts.count > 1 || parts.first.map({ ContextColors.label($0.name, main: main) != ContextColors.label(series, main: main) }) == true {
            lines += parts.map { "\(ContextColors.label($0.name, main: main)): \(Format.tokens($0.tokens))" }
        }
        return lines.joined(separator: "\n")
    }
}

/// What the shown call's context holds: one row per file, command, prompt,
/// and one for Claude's answers (or one per item), largest first. It follows
/// the call under the pointer, as the side panel does.
struct ContextHoldings: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let dir: String
    let lane: AnatomyLane
    /// An index into `lane.context`.
    let call: Int
    @State private var each = false
    @State private var showAll = false
    /// The most rows a call of this lane has, so the list keeps its height
    /// while the pointer moves from call to call.
    @State private var most: Int?
    @State private var shownCall: CallRef?

    private static let limit = 15

    var body: some View {
        let rows = ContextContents.rows(lane, call: call, each: each, dir: dir)
        let total = lane.context.indices.contains(call) ? lane.context[call].total : 0
        let shown = showAll ? rows : Array(rows.prefix(Self.limit))
        let reserved = showAll ? 0 : max(min(most ?? 0, Self.limit) - shown.count, 0)
        let widths = HoldingRow.Widths(shown, total: total)
        VStack(alignment: .leading, spacing: 6) {
            FlowRows(spacing: 14, lineSpacing: 8) {
                Text("What is in the context at call \(call + 1)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Picker("", selection: $each) {
                    Text("By file and command").tag(false)
                    Text("Each addition").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("By file and command: the reads of one file are one row, and Claude's answers are one row. Each addition: every prompt, tool result and answer on its own.")
            }
            Text("Tokens of this call's context. Each row is estimated; together they make the exact size. Start is the system prompt, the tools, CLAUDE.md and the first prompt. Other is text that came with no prompt or tool call before it.")
                .font(.system(size: 12)).foregroundStyle(Ink.text3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { row in
                    Rectangle().fill(Ink.line2).frame(height: 1)
                    let target = target(row)
                    HoldingRow(row: row, total: total, main: lane.id == "main", widths: widths, action: target.map { t in { open(t) } })
                        .rowMenu(view: viewAction(target),
                                 goTo: target.map { t in { model.openInChat(ChatPlace(lane: lane.id, event: t)) } },
                                 fileName: RowExport.fileName(sessionID: sessionID, name: "context call \(call + 1) \(row.label)"),
                                 json: { try RowExport.encode(RowExport.contextHolding(row, lane: lane, call: call, sessionID: sessionID)) })
                }
                // Empty rows, so the page below does not move with the pointer.
                ForEach(0 ..< reserved, id: \.self) { _ in
                    Color.clear.frame(height: HoldingRow.height + 1)
                }
            }
            .font(.system(size: 12.5))
            .monospacedDigit()
            .padding(.top, 4)
            if rows.count > Self.limit {
                Button(showAll ? "Show the largest \(Self.limit)" : "Show all \(rows.count)") { showAll.toggle() }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .task(id: "\(lane.id) \(each)") {
            most = ContextContents.mostRows(lane, each: each, dir: dir)
        }
        .sheet(item: $shownCall) { ref in
            if lane.events.indices.contains(ref.index) {
                CallSheet(sessionID: sessionID, lane: lane, index: ref.index)
            }
        }
    }

    /// The event a click opens: the largest of the row's. None for Start and Other.
    private func target(_ row: ContextRow) -> Int? {
        row.events.first { lane.events.indices.contains($0) }
    }

    /// The menu's View: only a tool call can be shown in full.
    private func viewAction(_ target: Int?) -> (() -> Void)? {
        guard let target, lane.events[target].hasFullCall else { return nil }
        return { open(target) }
    }

    private func open(_ event: Int) {
        if lane.events[event].hasFullCall {
            shownCall = CallRef(lane: lane.id, index: event)
        } else {
            model.openInChat(ChatPlace(lane: lane.id, event: event))
        }
    }
}

/// One row of `ContextHoldings`: tokens, share, part, what it is, how many times.
private struct HoldingRow: View {
    let row: ContextRow
    let total: UInt64
    let main: Bool
    let widths: Widths
    /// Nil: the row opens nothing (Start, Other).
    let action: (() -> Void)?
    @State private var hovering = false

    static let height: CGFloat = 30
    private static let inset: CGFloat = 6

    struct Widths {
        var tokens: CGFloat = 48
        var share: CGFloat = 36
        var part: CGFloat = 70
        var times: CGFloat = 0

        init(_ rows: [ContextRow], total: UInt64) {
            let bold = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
            let plain = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
            for row in rows {
                tokens = max(tokens, textWidth(Format.tokens(row.tokens), bold) + 10)
                share = max(share, textWidth(HoldingRow.share(row.tokens, total), plain) + 10)
                part = max(part, textWidth(ContextColors.label(row.part, main: true), plain) + 14 + 14)
                if row.events.count > 1 { times = max(times, textWidth("×\(row.events.count)", plain) + 12) }
            }
        }
    }

    nonisolated static func share(_ tokens: UInt64, _ total: UInt64) -> String {
        Format.percent(total == 0 ? 0 : Double(tokens) / Double(total))
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(Format.tokens(row.tokens)).fontWeight(.semibold)
                .frame(width: widths.tokens, alignment: .leading)
            Text(Self.share(row.tokens, total)).foregroundStyle(Ink.text3)
                .frame(width: widths.share, alignment: .leading)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(ContextColors.color(row.part)).frame(width: 8, height: 8)
                Text(ContextColors.label(row.part, main: main)).lineLimit(1).fixedSize()
            }
            .frame(width: widths.part, alignment: .leading)
            Text(row.label == row.part ? "" : row.label)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if widths.times > 0 {
                Text(row.events.count > 1 ? "×\(row.events.count)" : "")
                    .foregroundStyle(Ink.text3)
                    .frame(width: widths.times, alignment: .trailing)
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, Self.inset)
        .background(hovering ? Ink.soft : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, -Self.inset)
        .contentShape(Rectangle())
        .help(help)
        .onHover { inside in
            guard action != nil, inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop() }
            hovering = false
        }
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var help: String {
        var lines = [row.label]
        if row.events.count > 1 {
            lines.append(row.part == "Claude output" ? "\(row.events.count) answers" : "In the context \(row.events.count) times")
        }
        if action != nil { lines.append("Click to see the largest one") }
        return lines.joined(separator: "\n")
    }
}

/// The prompts and tool calls that added the most tokens to a context. A click
/// on a row shows the call in full; a prompt has no call, so it opens in Chat.
struct Contributors: View {
    @Environment(AppModel.self) private var model
    let anatomy: Anatomy
    @State private var shownCall: CallRef?

    var body: some View {
        let rows = anatomy.contributors.compactMap { c -> Line? in
            guard let lane = anatomy.lane(c.lane), lane.events.indices.contains(c.event) else { return nil }
            return Line(contributor: c, lane: lane, event: lane.events[c.event], where_: where_(lane, c.event))
        }
        let widths = Widths(rows)
        VStack(alignment: .leading, spacing: 6) {
            Text("Largest additions to the context").font(.system(size: 13, weight: .semibold))
            Text("Each one stays in every later call of its lane until a compaction, so it is read again on each call.")
                .font(.system(size: 12)).foregroundStyle(Ink.text3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(Ink.line2).frame(height: 1)
                    ContributorRow(line: row, widths: widths, color: color(row.event), action: { open(row) })
                        .rowMenu(view: row.event.hasFullCall ? { open(row) } : nil,
                                 goTo: { model.openInChat(row.place) },
                                 fileName: RowExport.fileName(sessionID: anatomy.sessionId, name: "\(row.event.label) \(row.event.text ?? "")"),
                                 json: { try RowExport.encode(await model.callExport(sessionID: anatomy.sessionId, lane: row.lane, event: row.contributor.event)) })
                }
            }
            .font(.system(size: 12.5))
            .monospacedDigit()
            .padding(.top, 4)
        }
        .sheet(item: $shownCall) { ref in
            if let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                CallSheet(sessionID: anatomy.sessionId, lane: lane, index: ref.index)
            }
        }
    }

    private func open(_ row: Line) {
        if row.event.hasFullCall {
            shownCall = CallRef(lane: row.lane.id, index: row.contributor.event)
        } else {
            model.openInChat(row.place)
        }
    }

    /// One row's values.
    fileprivate struct Line {
        var contributor: Contributor
        var lane: AnatomyLane
        var event: AnatomyEvent
        var where_: String
        var tokens: String { "+\(Format.tokens(contributor.tokens))" }
        var place: ChatPlace { ChatPlace(lane: lane.id, event: contributor.event) }
    }

    /// The columns' widths, so that they line up from row to row.
    fileprivate struct Widths {
        var tokens: CGFloat = 64
        var label: CGFloat = 70
        var where_: CGFloat = 0

        init(_ rows: [Line]) {
            let bold = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
            let plain = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
            for row in rows {
                tokens = max(tokens, textWidth(row.tokens, bold))
                label = max(label, textWidth(row.event.label, plain) + 14)
                where_ = max(where_, textWidth(row.where_, plain))
            }
        }
    }

    private func color(_ e: AnatomyEvent) -> Color {
        switch e.kind {
        case .tool: ContextColors.color("Tool: \(e.tool ?? "")")
        case .prompt: ContextColors.prompts
        case .compact: ContextColors.summary
        case .answer: ContextColors.output
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

/// One row of `Contributors`. The whole row lights up under the pointer, to
/// show that a click opens it.
private struct ContributorRow: View {
    let line: Contributors.Line
    let widths: Contributors.Widths
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    /// How far the highlight reaches past the text.
    private static let inset: CGFloat = 6

    var body: some View {
        let e = line.event
        HStack(spacing: 0) {
            Text(line.tokens).fontWeight(.semibold)
                .frame(width: widths.tokens, alignment: .leading)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(e.label).lineLimit(1).fixedSize()
            }
            .frame(width: widths.label, alignment: .leading)
            Text(e.command ?? e.text ?? "")
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(line.where_)
                .foregroundStyle(Ink.text3)
                .lineLimit(1)
                .fixedSize()
                .frame(width: widths.where_, alignment: .trailing)
                .padding(.leading, 12)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, Self.inset)
        .background(hovering ? Ink.soft : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, -Self.inset)
        .contentShape(Rectangle())
        .help("\(line.lane.name) · \(e.start.formatted(date: .omitted, time: .standard))")
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // The tab can change under the pointer: a prompt row opens Chat.
        .onDisappear {
            if hovering { NSCursor.pop() }
            hovering = false
        }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(e.hasFullCall ? "Shows this call in full" : "Shows this prompt in Chat")
    }
}

/// Lays its children out in rows, wrapping to a new row when one is full, as
/// `display: flex; flex-wrap: wrap; align-items: center` with a gap.
struct FlowRows: Layout {
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
            for (i, size) in zip(row.items, row.sizes) {
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// An item wider than the row gets the row's width (a text then wraps).
    private func size(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width, width.isFinite else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = size(subviews[i], width: width)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            row.sizes.append(size)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
