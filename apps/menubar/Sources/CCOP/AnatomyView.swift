import CCOPKit
import SwiftUI

/// A lane id and an index into its events.
struct EventRef: Hashable {
    var lane: String
    var index: Int
}

enum Palette {
    static let answer = Color.indigo.opacity(0.45)
    static let prompt = Color.green
    static let compact = Color.red
    static let error = Color.red

    /// A fixed color for common tools; others get one by their name.
    static func tool(_ name: String?) -> Color {
        switch name ?? "" {
        case "Bash": return .orange
        case "Read": return .blue
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return .green
        case "Grep", "Glob": return .teal
        case "WebSearch", "WebFetch": return .purple
        case "Agent", "Task", "SendMessage", "SubagentHandback": return .pink
        case "ToolSearch", "Skill": return .cyan
        default:
            let colors: [Color] = [.mint, .cyan, .brown, .yellow, .red.opacity(0.7)]
            let sum = (name ?? "").unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return colors[sum % colors.count]
        }
    }

    static func event(_ e: AnatomyEvent) -> Color {
        switch e.kind {
        case .prompt: prompt
        case .answer: answer
        case .tool: tool(e.tool)
        case .compact: compact
        case .error: error
        }
    }
}

/// The anatomy tab: what the session did, when, in which lane.
struct AnatomyView: View {
    let session: Session
    let anatomy: Anatomy
    @State private var selected: EventRef?

    var body: some View {
        let a = anatomy
        let scale = TimeScale(spans: spans(a))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StatsRow(anatomy: a, scale: scale)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Timeline").font(.headline)
                    Text("One row per lane. Gray: model calls. Colors: tool calls. Green line: a prompt. Red line: a compaction. Idle gaps over 2 minutes are shortened. Zoom: pinch, scroll with ⌥, or ⌘+ and ⌘−; drag or scroll sideways to move.")
                        .font(.caption).foregroundStyle(.secondary)
                    TimelineChart(anatomy: a, scale: scale, selected: $selected)
                        // Above the legend and tables, so its hover card is not under them.
                        .zIndex(1)
                    Legend(tools: a.tools.prefix(10).map(\.tool))
                }
                // The hover card can reach below the timeline: keep it above what follows.
                .zIndex(1)
                if let ref = selected, let lane = a.lane(ref.lane), lane.events.indices.contains(ref.index) {
                    EventCard(anatomy: a, lane: lane, event: lane.events[ref.index]) { selected = $0 }
                }
                HStack(alignment: .top, spacing: 24) {
                    ToolTable(tools: a.tools)
                    if a.lanes.count > 1 { SubagentTable(anatomy: a) }
                }
                TurnList(anatomy: a, selected: $selected)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func spans(_ a: Anatomy) -> [(Date, Date)] {
        a.lanes.flatMap { $0.events.map { ($0.start, $0.end) } }
    }
}

struct StatsRow: View {
    let anatomy: Anatomy
    let scale: TimeScale

    var body: some View {
        let a = anatomy
        let calls = a.lanes.reduce(0) { $0 + $1.events.filter { $0.kind == .answer }.count }
        let tools = a.lanes.reduce(UInt64(0)) { $0 + $1.toolCalls }
        let errors = a.lanes.reduce(UInt64(0)) { $0 + $1.errors }
        let span = (a.startedAt.flatMap { s in a.endedAt.map { $0.timeIntervalSince(s) } }) ?? 0
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 10) {
            stat(Format.duration(span), "from first to last event")
            stat(Format.duration(scale.activeSeconds), "active (without idle gaps)")
            stat("\(a.turns.filter { $0.index > 0 }.count)", "prompts")
            stat("\(calls)", "model calls")
            stat("\(tools)", "tool calls")
            stat("\(errors)", "tool errors")
            stat("\(a.lanes.count - 1)", "subagents")
            stat("\(a.compactions)", "compactions")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Legend: View {
    let tools: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
            item("Model call", Palette.answer)
            item("Prompt", Palette.prompt)
            item("Compaction", Palette.compact)
            ForEach(tools, id: \.self) { item($0, Palette.tool($0)) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(name).lineLimit(1)
        }
    }
}

/// Scroll wheel events over the timeline: ⌥ or ⌘ with a vertical scroll
/// zooms at the pointer; a sideways scroll moves a zoomed timeline. Other
/// scrolls go on to the page. SwiftUI on macOS 14 has no scroll wheel
/// handler, so this is a local event monitor, active while the window is open.
@MainActor
final class TimelineWheel {
    /// The pointer's x on the timeline, while it is over it.
    var pointerX: CGFloat?
    var width: CGFloat = 0
    private var monitor: Any?

    func start(_ window: Binding<TimeWindow>) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let x = self.pointerX, self.width > 0 else { return event }
            let fine = event.hasPreciseScrollingDeltas
            if !event.modifierFlags.intersection([.option, .command]).isEmpty {
                // Up or away from you zooms in, whatever the scroll direction setting.
                let dy = Double(event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY)
                window.wrappedValue.zoom(by: exp(dy * (fine ? 0.01 : 0.1)), at: Double(x / self.width))
                return nil
            }
            let dx = event.scrollingDeltaX * (fine ? 1 : 10)
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), !window.wrappedValue.isWhole {
                window.wrappedValue.pan(by: -Double(dx / self.width))
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The lanes drawn on one time axis. Hover shows an event; a click selects
/// it. Pinch, ⌥-scroll or the buttons zoom; a drag or a sideways scroll moves.
struct TimelineChart: View {
    let anatomy: Anatomy
    let scale: TimeScale
    @Binding var selected: EventRef?
    @State private var hover: (EventRef, CGPoint)?
    /// The part of the timeline that is shown.
    @State private var window = TimeWindow()
    @State private var dragStart: TimeWindow?
    @State private var pinchStart: TimeWindow?
    @State private var wheel = TimelineWheel()

    static let rowHeight: CGFloat = 22
    static let axisHeight: CGFloat = 22
    static let labelWidth: CGFloat = 230
    /// Room under the rows for the idle gap labels.
    static let gapLabelHeight: CGFloat = 16
    /// How far a press may move and still be a click.
    static let clickSlop: CGFloat = 3

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            controls
            chart
        }
        .onAppear { wheel.start($window) }
        .onDisappear { wheel.stop() }
        .onChange(of: anatomy.sessionId) { window = TimeWindow() }
        .onChange(of: selected) {
            // A call chosen in the turn list: show it when it is outside the view.
            if let ref = selected, let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                window.reveal(scale.position(lane.events[ref.index].start))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if !window.isWhole {
                Text("\(shownTime) shown, \(zoomText)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { window.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
                .disabled(window.isWhole)
            Button { window.zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+). Or pinch, or scroll with ⌥ over the timeline.")
                .disabled(window.span <= TimeWindow.minSpan)
            Button("Fit") { window = TimeWindow() }
                .keyboardShortcut("0", modifiers: .command)
                .help("Show the whole session (⌘0)")
                .disabled(window.isWhole)
        }
        .controlSize(.small)
    }

    private var zoomText: String {
        let z = window.zoom
        return z < 10 ? String(format: "%.1f×", z) : String(format: "%.0f×", z)
    }

    private var shownTime: String {
        Format.duration(window.span * scale.shownSeconds)
    }

    private var chart: some View {
        let lanes = anatomy.lanesInTreeOrder
        let height = Self.axisHeight + CGFloat(lanes.count) * Self.rowHeight + Self.gapLabelHeight
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.axisHeight)
                ForEach(lanes) { lane in
                    HStack(spacing: 4) {
                        Text(lane.name).lineLimit(1).truncationMode(.tail)
                            .padding(.leading, CGFloat(anatomy.depth(of: lane)) * 12)
                        Spacer(minLength: 2)
                        Text(Format.tokens(lane.usage.total)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                    .frame(height: Self.rowHeight)
                    .help("\(lane.name)\n\(lane.agentType ?? "") \(lane.model ?? "")\n\(Format.duration(lane.duration)), \(lane.toolCalls) tool calls")
                }
            }
            .frame(width: Self.labelWidth)
            .padding(.trailing, 8)
            GeometryReader { geo in
                let width = geo.size.width
                Canvas { ctx, size in
                    draw(ctx, size: size, lanes: lanes)
                }
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p):
                        hover = dragStart == nil ? hit(p, width: width, lanes: lanes).map { ($0, p) } : nil
                        wheel.pointerX = p.x
                        wheel.width = width
                    case .ended:
                        hover = nil
                        wheel.pointerX = nil
                    }
                }
                // One gesture for click and drag: a press that does not move is a click.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard dragStart != nil || abs(v.translation.width) > Self.clickSlop else { return }
                            let start = dragStart ?? window
                            dragStart = start
                            hover = nil
                            var w = start
                            w.pan(by: -Double(v.translation.width / max(width, 1)))
                            window = w
                        }
                        .onEnded { v in
                            if dragStart == nil { selected = hit(v.startLocation, width: width, lanes: lanes) }
                            dragStart = nil
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            let start = pinchStart ?? window
                            pinchStart = start
                            var w = start
                            w.zoom(by: v.magnification, at: Double(v.startLocation.x / max(width, 1)))
                            window = w
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .overlay(alignment: .topLeading) {
                    if let (ref, p) = hover, let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                        HoverCard(lane: lane, event: lane.events[ref.index])
                            .offset(x: min(p.x + 12, max(0, width - 320)), y: p.y + 14)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: height)
        .padding(.vertical, 4)
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(window.view(scale.position(date))) * width
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, lanes: [AnatomyLane]) {
        let w = size.width
        let rh = Self.rowHeight
        let top = Self.axisHeight
        let bottom = size.height - Self.gapLabelHeight
        // Axis: times along the top, every ~140 px; with seconds when ticks are under 2 minutes apart.
        let ticks = max(2, Int(w / 140))
        let seconds = window.span * scale.shownSeconds / Double(ticks) < 120
        for i in 0 ... ticks {
            let v = Double(i) / Double(ticks)
            guard let d = scale.date(at: window.position(atView: v)) else { continue }
            let px = CGFloat(v) * w
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: top - 4)); $0.addLine(to: CGPoint(x: px, y: bottom)) },
                       with: .color(.secondary.opacity(0.12)))
            let time = seconds ? d.formatted(.dateTime.hour().minute().second()) : d.formatted(date: .omitted, time: .shortened)
            let label = Text(time).font(.caption2).foregroundStyle(.secondary)
            ctx.draw(label, at: CGPoint(x: min(max(px, 24), w - 24), y: 8))
        }
        // Idle gaps.
        for gap in scale.gaps {
            let px = CGFloat(window.view(gap.position)) * w
            guard px >= -40, px <= w + 40 else { continue }
            var path = Path()
            path.move(to: CGPoint(x: px, y: top))
            path.addLine(to: CGPoint(x: px, y: bottom))
            ctx.stroke(path, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text("idle \(Format.duration(gap.duration))").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: min(max(px, 30), w - 30), y: bottom + 2), anchor: .top)
        }
        let rowOf = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
        for (row, lane) in lanes.enumerated() {
            let y = top + CGFloat(row) * rh
            if row % 2 == 1 {
                ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: rh)), with: .color(.secondary.opacity(0.05)))
            }
            if let s = lane.startedAt, let e = lane.endedAt {
                let r = CGRect(x: x(s, w), y: y + rh * 0.42, width: max(1, x(e, w) - x(s, w)), height: rh * 0.16)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(.secondary.opacity(0.25)))
            }
            for (i, e) in lane.events.enumerated() {
                let x0 = x(e.start, w)
                let width = max(1.5, x(e.end, w) - x0)
                // Outside the view: not drawn (Canvas clips it anyway).
                guard x0 + width >= -4, x0 <= w + 4 else { continue }
                let isSelected = selected == EventRef(lane: lane.id, index: i)
                switch e.kind {
                case .answer:
                    let r = CGRect(x: x0, y: y + rh * 0.3, width: width, height: rh * 0.4)
                    ctx.fill(Path(r), with: .color(Palette.answer))
                case .tool:
                    let r = CGRect(x: x0, y: y + rh * 0.15, width: width, height: rh * 0.7)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Palette.tool(e.tool)))
                    if e.isError {
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(.red), lineWidth: 1.5)
                    }
                    // A line down to the subagent this call started.
                    if let agent = e.agentId, let childRow = rowOf[agent], childRow > row {
                        var link = Path()
                        link.move(to: CGPoint(x: x0, y: y + rh * 0.85))
                        link.addLine(to: CGPoint(x: x0, y: top + CGFloat(childRow) * rh + rh * 0.5))
                        ctx.stroke(link, with: .color(Palette.tool(e.tool).opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                case .prompt:
                    ctx.fill(Path(CGRect(x: x0 - 1, y: y + 1, width: 2.5, height: rh - 2)), with: .color(Palette.prompt))
                case .compact:
                    ctx.fill(Path(CGRect(x: x0 - 1, y: y, width: max(3, width), height: rh)), with: .color(Palette.compact))
                case .error:
                    ctx.fill(Path(ellipseIn: CGRect(x: x0 - 3, y: y + rh / 2 - 3, width: 6, height: 6)), with: .color(Palette.error))
                }
                if isSelected {
                    let r = CGRect(x: x0 - 2, y: y + 1, width: width + 4, height: rh - 2)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.primary), lineWidth: 2)
                }
            }
        }
    }

    /// The event under a point: tools first (they are drawn on top), then
    /// prompts and compactions, then model calls.
    private func hit(_ p: CGPoint, width: CGFloat, lanes: [AnatomyLane]) -> EventRef? {
        let row = Int((p.y - Self.axisHeight) / Self.rowHeight)
        guard p.y >= Self.axisHeight, lanes.indices.contains(row) else { return nil }
        let lane = lanes[row]
        var best: (Int, Int, CGFloat)?
        for (i, e) in lane.events.enumerated() {
            let x0 = x(e.start, width) - 3
            let x1 = max(x(e.end, width), x0 + 4.5) + 3
            guard p.x >= x0, p.x <= x1 else { continue }
            let rank = switch e.kind {
            case .tool: 0
            case .prompt, .compact, .error: 1
            case .answer: 2
            }
            let dist = abs(p.x - (x0 + x1) / 2)
            if best == nil || rank < best!.1 || (rank == best!.1 && dist < best!.2) { best = (i, rank, dist) }
        }
        return best.map { EventRef(lane: lane.id, index: $0.0) }
    }
}

/// The small card next to the pointer.
struct HoverCard: View {
    let lane: AnatomyLane
    let event: AnatomyEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(Palette.event(event)).frame(width: 10, height: 10)
                Text(event.label).fontWeight(.semibold)
                Text(Format.duration(event.duration)).foregroundStyle(.secondary)
                if event.isError { Text("error").foregroundStyle(.red) }
            }
            if let t = event.text { Text(t).lineLimit(3) }
            Text(EventFacts.line(event)).foregroundStyle(.secondary)
            Text(lane.name).foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(8)
        .frame(width: 300, alignment: .leading)
        // Opaque: a material lets the chart and legend show through.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

enum EventFacts {
    /// Tokens and sizes of an event, in one line.
    static func line(_ e: AnatomyEvent) -> String {
        var parts: [String] = [e.start.formatted(date: .omitted, time: .standard)]
        switch e.kind {
        case .answer:
            if let c = e.contextTokens { parts.append("context \(Format.tokens(c))") }
            if let u = e.usage {
                parts.append("output \(Format.tokens(u.outputTokens))")
                if u.cacheWriteTokens > 0 { parts.append("cache write \(Format.tokens(u.cacheWriteTokens))") }
            }
            if let m = e.model { parts.append(m) }
        case .tool:
            if let b = e.resultBytes { parts.append("returned \(Format.bytes(b))") } else { parts.append("no result") }
            if let t = e.addedTokens { parts.append("+\(Format.tokens(t)) context") }
        case .prompt, .compact:
            if let t = e.addedTokens { parts.append("+\(Format.tokens(t)) context") }
        case .error:
            break
        }
        return parts.joined(separator: " · ")
    }
}

/// The selected event, with a link to the subagent it started.
struct EventCard: View {
    let anatomy: Anatomy
    let lane: AnatomyLane
    let event: AnatomyEvent
    let select: (EventRef?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(Palette.event(event)).frame(width: 12, height: 12)
                Text(event.label).font(.headline)
                Text("in \(lane.name)").foregroundStyle(.secondary)
                Spacer()
                Button { select(nil) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Text("\(event.start.formatted(date: .omitted, time: .standard)) → \(event.end.formatted(date: .omitted, time: .standard)), \(Format.duration(event.duration))")
                .foregroundStyle(.secondary)
            if let t = event.text { Text(t).textSelection(.enabled) }
            Text(EventFacts.line(event)).foregroundStyle(.secondary)
            if let agent = event.agentId, let sub = anatomy.lane(agent) {
                Text("Started the subagent “\(sub.name)”: \(Format.duration(sub.duration)), \(Format.tokens(sub.usage.total)) tokens, \(sub.toolCalls) tool calls.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolTable: View {
    let tools: [ToolStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tools").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Tool").gridColumnAlignment(.leading)
                    Text("Calls")
                    Text("Errors")
                    Text("Time")
                    Text("Returned")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(tools) { t in
                    GridRow {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(Palette.tool(t.tool)).frame(width: 8, height: 8)
                            Text(t.tool).lineLimit(1)
                        }
                        Text("\(t.calls)")
                        Text(t.errors > 0 ? "\(t.errors)" : "").foregroundStyle(.red)
                        Text(Format.duration(Double(t.totalMs) / 1000))
                        Text(Format.bytes(t.resultBytes))
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
            Text("Time adds up the time from each call to its result; calls that ran in parallel add up too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 380, alignment: .leading)
    }
}

struct SubagentTable: View {
    let anatomy: Anatomy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Subagents").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Description").gridColumnAlignment(.leading)
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Start")
                    Text("Time")
                    Text("Tokens")
                    Text("Tools")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(anatomy.lanesInTreeOrder.filter { $0.id != "main" }) { l in
                    GridRow {
                        Text(l.name).lineLimit(1).padding(.leading, CGFloat(anatomy.depth(of: l) - 1) * 12)
                            .help(l.agentType ?? "")
                        Text((l.model ?? "").replacingOccurrences(of: "claude-", with: "")).foregroundStyle(.secondary)
                        Text(l.startedAt?.formatted(date: .omitted, time: .shortened) ?? "")
                        Text(Format.duration(l.duration))
                        Text(Format.tokens(l.usage.total))
                        Text(l.errors > 0 ? "\(l.toolCalls) (\(l.errors) err)" : "\(l.toolCalls)")
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Each prompt with what it caused; expand a turn to see each call.
struct TurnList: View {
    let anatomy: Anatomy
    @Binding var selected: EventRef?
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turns").font(.headline)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(anatomy.turns) { turn in
                    DisclosureGroup(isExpanded: binding(turn.id)) {
                        TurnEvents(anatomy: anatomy, turn: turn, selected: $selected)
                            .padding(.leading, 4)
                    } label: {
                        TurnHeader(turn: turn)
                    }
                    Divider()
                }
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { open.contains(id) }, set: { if $0 { open.insert(id) } else { open.remove(id) } })
    }
}

struct TurnHeader: View {
    let turn: Turn

    var body: some View {
        HStack(spacing: 10) {
            Text(turn.index == 0 ? "–" : "#\(turn.index)").monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Text(turn.start.formatted(date: .omitted, time: .shortened)).monospacedDigit().frame(width: 52, alignment: .leading)
            Text(turn.prompt).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(Format.duration(turn.duration)).frame(width: 70, alignment: .trailing)
                Text("\(turn.answers) calls").frame(width: 70, alignment: .trailing)
                Text("\(turn.toolCalls) tools").frame(width: 70, alignment: .trailing)
                Text(Format.tokens(turn.usage.total)).frame(width: 60, alignment: .trailing)
                    .help("Tokens of the main session in this turn")
                Text(turn.subagents.isEmpty ? "" : "+\(Format.tokens(turn.subagentUsage.total)) in \(turn.subagents.count) sub")
                    .frame(width: 120, alignment: .trailing)
                    .help("Tokens of the subagents started in this turn")
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// The events of a turn's main lane; an Agent call opens to its subagent's events.
struct TurnEvents: View {
    let anatomy: Anatomy
    let turn: Turn
    @Binding var selected: EventRef?

    var body: some View {
        let main = anatomy.lane("main")
        VStack(alignment: .leading, spacing: 1) {
            ForEach(anatomy.mainEventIndices(in: turn), id: \.self) { i in
                let e = main!.events[i]
                let ref = EventRef(lane: "main", index: i)
                EventRow(event: e, depth: 0, isSelected: selected == ref) { selected = ref }
                if let agent = e.agentId, let sub = anatomy.lane(agent) {
                    SubagentEvents(anatomy: anatomy, lane: sub, depth: 1, selected: $selected)
                }
            }
        }
    }
}

struct SubagentEvents: View {
    let anatomy: Anatomy
    let lane: AnatomyLane
    let depth: Int
    @Binding var selected: EventRef?
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lane.events.enumerated()), id: \.offset) { i, e in
                    let ref = EventRef(lane: lane.id, index: i)
                    EventRow(event: e, depth: depth, isSelected: selected == ref) { selected = ref }
                    if let agent = e.agentId, let sub = anatomy.lane(agent) {
                        SubagentEvents(anatomy: anatomy, lane: sub, depth: depth + 1, selected: $selected)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(Palette.tool("Agent"))
                Text("Subagent: \(lane.name)").fontWeight(.medium)
                Text("\(Format.duration(lane.duration)) · \(Format.tokens(lane.usage.total)) tokens · \(lane.toolCalls) tools · \(lane.model ?? "")")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.leading, CGFloat(depth) * 18)
    }
}

struct EventRow: View {
    let event: AnatomyEvent
    let depth: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let e = event
        HStack(spacing: 8) {
            Text(e.start.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Palette.event(e)).frame(width: 8, height: 8)
            Text(e.label).fontWeight(e.kind == .tool ? .medium : .regular).frame(width: 110, alignment: .leading).lineLimit(1)
            Text(e.text ?? "").lineLimit(1).foregroundStyle(e.kind == .answer ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if e.isError { Text("error").foregroundStyle(.red) }
            Text(Format.duration(e.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(tokens(e)).monospacedDigit().foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * 18 + 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private func tokens(_ e: AnatomyEvent) -> String {
        switch e.kind {
        case .answer:
            let ctx = e.contextTokens.map { "ctx \(Format.tokens($0))" } ?? ""
            let out = e.usage.map { "out \(Format.tokens($0.outputTokens))" } ?? ""
            return [ctx, out].filter { !$0.isEmpty }.joined(separator: " · ")
        case .tool, .prompt, .compact:
            return e.addedTokens.map { "+\(Format.tokens($0)) ctx" } ?? ""
        case .error:
            return ""
        }
    }
}
