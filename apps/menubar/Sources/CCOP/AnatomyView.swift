import AppKit
import CCOPKit
import SwiftUI

/// A lane id and an index into its events.
struct EventRef: Hashable {
    var lane: String
    var index: Int
}

/// Event colors. Other tabs use it too; the colors come from `Theme`.
enum Palette {
    static let answer = Theme.modelCall
    static let prompt = Theme.prompt
    static let compact = Theme.bad
    static let error = Theme.bad

    static func tool(_ name: String?) -> Color {
        Theme.tool(name ?? "").color
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

/// Text colours, lines and fills of the anatomy tab, as in the design board
/// (light value, then dark value).
private enum Ink {
    static let text = Theme.dynamic(0x1D1D1F, 0xF2F2F4)
    static let text2 = Theme.dynamic(0x5F5F64, 0xB9B9BF)
    static let text3 = Theme.dynamic(0x6E6E73, 0xA1A1A8)
    static let line = shade(0.10, 0.12)
    static let line2 = shade(0.06, 0.07)
    static let track = shade(0.07, 0.12)
    static let hatch = shade(0.05, 0.07)
    /// The page and the timeline box: #FFFFFF in light mode.
    static let bg = Theme.page
    /// The axis row and a hovered turn: #F7F7F8 in light mode.
    static let soft = Theme.card
    static let callout = Theme.dynamic(0x1D1D1F, 0x48484A)

    /// Black at `light` alpha in light mode, white at `dark` alpha in dark mode.
    private static func shade(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        })
    }
}

/// `48 s`, `38 min`, `5 h 19 min`.
func shortDuration(_ seconds: TimeInterval) -> String {
    if seconds < 1 { return Format.duration(seconds) }
    if seconds < 60 { return "\(Int(seconds.rounded())) s" }
    let m = Int((seconds / 60).rounded())
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
}

/// `claude-opus-5-5` → `opus 5.5`; `claude-3-5-haiku-20241022` → `haiku 3.5`.
func shortModel(_ model: String?) -> String? {
    guard var m = model, !m.isEmpty, m != "<synthetic>" else { return nil }
    if m.hasPrefix("claude-") { m.removeFirst(7) }
    let parts = m.split(separator: "-")
    guard let family = parts.first(where: { !$0.allSatisfy(\.isNumber) }) else { return m }
    let version = parts.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
    return version.isEmpty ? String(family) : "\(family) \(version.joined(separator: "."))"
}

func plural(_ n: Int, _ word: String) -> String {
    "\(n) \(word)\(n == 1 ? "" : "s")"
}

/// The anatomy tab: what the session did, when, in which lane.
struct AnatomyView: View {
    let session: Session
    let anatomy: Anatomy
    @State private var selected: EventRef?

    var body: some View {
        let a = anatomy
        let scale = Self.scale(a)
        PageScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    TimelineChart(anatomy: a, scale: scale, selected: $selected)
                        // Above the legend, so its callout is not under it.
                        .zIndex(1)
                    AnatomyLegend(anatomy: a)
                }
                // The callout can reach below the timeline: keep it above what follows.
                .zIndex(1)
                ToolCards(anatomy: a)
                TurnList(anatomy: a, selected: $selected)
            }
            .font(.system(size: 13))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The time scale, with each idle gap a few percent of the width: wide
    /// enough to see its hatch, and all gaps together at most a fifth of it.
    static func scale(_ a: Anatomy) -> TimeScale {
        let spans = a.lanes.flatMap { $0.events.map { ($0.start, $0.end) } }
        let first = TimeScale(spans: spans)
        guard !first.gaps.isEmpty else { return first }
        let active = first.activeSeconds
        let width = min(active * 0.2 / Double(first.gaps.count), max(30, active * 0.025))
        return TimeScale(spans: spans, gapWidth: max(1, width))
    }
}

// MARK: - Timeline

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

/// An idle gap on screen: its x range on the track area and how long it was.
private struct GapRange {
    var lo: Double
    var hi: Double
    var x0: CGFloat
    var x1: CGFloat
    var duration: TimeInterval
}

/// The lanes on one time axis. Each lane has two tracks: model calls on top,
/// tool calls below. Hover shows an event; a click selects it. Pinch,
/// ⌥-scroll or the buttons zoom; a drag or a sideways scroll moves.
struct TimelineChart: View {
    @Environment(AppModel.self) private var model
    let anatomy: Anatomy
    let scale: TimeScale
    @Binding var selected: EventRef?
    @State private var hover: EventRef?
    /// The lane whose label was clicked: its whole row is highlighted.
    @State private var pickedLane: String?
    @State private var hoverLane: String?
    /// The part of the timeline that is shown.
    @State private var window = TimeWindow()
    @State private var dragStart: TimeWindow?
    @State private var pinchStart: TimeWindow?
    @State private var wheel = TimelineWheel()

    static let labelWidth: CGFloat = 200
    static let laneHeight: CGFloat = 52
    static let axisHeight: CGFloat = 28
    static let callTop: CGFloat = 12
    static let callHeight: CGFloat = 8
    static let toolTop: CGFloat = 26
    static let toolHeight: CGFloat = 14
    /// For hit tests: above this line is the model call track, below it the tools.
    static let splitY: CGFloat = 23
    /// The dashed line through the model call track.
    static let dashY: CGFloat = 17
    /// How far a press may move and still be a click.
    static let clickSlop: CGFloat = 3

    var body: some View {
        let lanes = anatomy.lanesInTreeOrder
        VStack(alignment: .leading, spacing: 10) {
            header
            box(lanes)
        }
        .onAppear { wheel.start($window) }
        .onDisappear { wheel.stop() }
        .onChange(of: anatomy.sessionId) { window = TimeWindow() }
        .onChange(of: selected) {
            // A call chosen elsewhere: its lane is the picked one now.
            if let picked = pickedLane, let lane = anatomy.lane(picked), selected == startingCall(of: lane) {
                // The label's own click: keep the subagent's row.
            } else {
                pickedLane = selected?.lane
            }
            // A call chosen in the turn list: show it when it is outside the view.
            if let e = event(selected) {
                window.reveal(scale.position(e.start))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("Timeline").font(.system(size: 13, weight: .semibold))
            Text(summary).font(.system(size: 12)).foregroundStyle(Ink.text3).monospacedDigit().lineLimit(1)
                .help(scale.gaps.isEmpty ? "" : "Active \(shortDuration(scale.activeSeconds))")
            Spacer(minLength: 0)
            if !window.isWhole {
                Text("\(shownTime) shown, \(zoomText)").font(.system(size: 12)).foregroundStyle(Ink.text3)
                    .monospacedDigit().lineLimit(1)
            }
            HStack(spacing: 4) {
                Button { window.zoom(by: 1 / 1.5) } label: { Text("−").font(.system(size: 13)) }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Zoom out (⌘−)")
                    .accessibilityLabel("Zoom out")
                Button { window.zoom(by: 1.5) } label: { Text("+").font(.system(size: 13)) }
                    .keyboardShortcut("=", modifiers: .command)
                    .help("Zoom in (⌘+). Or pinch, or scroll with ⌥ over the timeline. Drag or scroll sideways to move.")
                    .accessibilityLabel("Zoom in")
                    .disabled(window.span <= TimeWindow.minSpan)
                Button { window = TimeWindow() } label: { Text("Fit").font(.system(size: 12)) }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Show the whole session (⌘0)")
                    .buttonStyle(ZoomButtonStyle(width: nil))
            }
            .buttonStyle(ZoomButtonStyle())
        }
        .frame(minHeight: 24)
    }

    private var summary: String {
        let span = anatomy.startedAt.flatMap { s in anatomy.endedAt.map { $0.timeIntervalSince(s) } } ?? 0
        var parts = [shortDuration(span)]
        if !scale.gaps.isEmpty {
            parts.append(scale.gaps.count == 1 ? "1 idle gap shortened" : "\(scale.gaps.count) idle gaps shortened")
        }
        return parts.joined(separator: " · ")
    }

    private var zoomText: String {
        let z = window.zoom
        return z < 10 ? String(format: "%.1f×", z) : String(format: "%.0f×", z)
    }

    private var shownTime: String {
        shortDuration(window.span * scale.shownSeconds)
    }

    // MARK: Box

    private func box(_ lanes: [AnatomyLane]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(lanes.enumerated()), id: \.element.id) { row, lane in
                        laneLabel(lane)
                            .frame(width: Self.labelWidth, height: Self.laneHeight, alignment: .leading)
                            .overlay(alignment: .top) {
                                if row > 0 { Rectangle().fill(Ink.line2).frame(height: 1) }
                            }
                    }
                }
                Rectangle().fill(Ink.line2).frame(width: 1)
                tracks(lanes)
            }
            .frame(height: CGFloat(lanes.count) * Self.laneHeight)
            .background(alignment: .topLeading) {
                // The picked lane: a tint across the label and the tracks.
                if let row = lanes.firstIndex(where: { $0.id == pickedLane }) {
                    Rectangle().fill(Theme.accent.opacity(0.09))
                        .frame(height: Self.laneHeight)
                        .offset(y: CGFloat(row) * Self.laneHeight)
                        .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Ink.line2).frame(height: 1)
            HStack(spacing: 0) {
                Text("Top: model calls · bottom: tools")
                    .font(.system(size: 11)).foregroundStyle(Ink.text3)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
                    .frame(width: Self.labelWidth, alignment: .leading)
                Rectangle().fill(Ink.line2).frame(width: 1)
                Canvas { ctx, size in drawAxis(ctx, size: size) }
            }
            .frame(height: Self.axisHeight)
            .background(Ink.soft)
        }
        .background(Ink.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
        // After the clip, so the callout can reach out of the box.
        .overlay(alignment: .topLeading) { calloutLayer(lanes) }
    }

    private func laneLabel(_ lane: AnatomyLane) -> some View {
        let isMain = lane.id == "main"
        let calls = lane.events.filter { $0.kind == .answer }.count
        let caption = [shortModel(lane.model), plural(calls, "call"), shortDuration(lane.duration)]
            .compactMap { $0 }.joined(separator: " · ")
        let depth = anatomy.depth(of: lane)
        let picked = pickedLane == lane.id
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(isMain ? Ink.text : Theme.agent)
                .frame(width: 4, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(isMain ? "Main" : lane.name)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text(caption).font(.system(size: 11)).foregroundStyle(Ink.text3).monospacedDigit().lineLimit(1)
            }
            if picked || hoverLane == lane.id {
                Spacer(minLength: 0)
                SmallIconButton(symbol: "bubble.left.and.text.bubble.right",
                                help: isMain ? "Open the main session's chat" : "Open this agent alone in Chat",
                                size: 24, fill: Theme.bg) {
                    model.chatLane = lane.id
                    model.windowTab = .chat
                }
            }
        }
        .onHover { hoverLane = $0 ? lane.id : (hoverLane == lane.id ? nil : hoverLane) }
        .padding(.leading, 14 + CGFloat(max(0, depth - 1)) * 10)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(laneHelp(lane))
        .onTapGesture {
            // A subagent's label selects the call that started it; the
            // lane's whole row is highlighted.
            if let start = startingCall(of: lane) { selected = start }
            pickedLane = lane.id
        }
    }

    private func laneHelp(_ lane: AnatomyLane) -> String {
        var lines = [lane.name]
        let kind = [lane.agentType, lane.model].compactMap { $0 }.joined(separator: ", ")
        if !kind.isEmpty { lines.append(kind) }
        if let s = lane.startedAt { lines.append("Started \(s.formatted(date: .omitted, time: .shortened)), ran \(shortDuration(lane.duration))") }
        lines.append("\(Format.tokens(lane.usage.total)) tokens, \(lane.toolCalls) tool calls, \(lane.errors) errors")
        if lane.id != "main" { lines.append("Click to highlight it and select the call that started it.") }
        return lines.joined(separator: "\n")
    }

    private func startingCall(of lane: AnatomyLane) -> EventRef? {
        guard let parentId = lane.parent, let parent = anatomy.lane(parentId),
              let i = parent.events.firstIndex(where: { $0.agentId == lane.id }) else { return nil }
        return EventRef(lane: parentId, index: i)
    }

    private func tracks(_ lanes: [AnatomyLane]) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { ctx, size in
                drawTracks(ctx, size: size, lanes: lanes)
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(p):
                    hover = dragStart == nil ? hit(p, width: width, lanes: lanes) : nil
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
        }
    }

    // MARK: Geometry

    private func event(_ ref: EventRef?) -> AnatomyEvent? {
        guard let ref, let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) else { return nil }
        return lane.events[ref.index]
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(window.view(scale.position(date))) * width
    }

    /// The idle gaps on screen, in the order of `scale.gaps`.
    private func gapRanges(_ w: CGFloat) -> [GapRange] {
        let segs = scale.segments
        guard segs.count > 1 else { return [] }
        return (1 ..< segs.count).compactMap { i in
            guard scale.gaps.indices.contains(i - 1) else { return nil }
            let prev = segs[i - 1]
            let lo = (prev.offset + prev.end.timeIntervalSince(prev.start)) / scale.shownSeconds
            let hi = segs[i].offset / scale.shownSeconds
            var x0 = CGFloat(window.view(lo)) * w
            var x1 = CGFloat(window.view(hi)) * w
            // At least a few pixels, so a narrow gap still shows.
            if x1 - x0 < 4 {
                let mid = (x0 + x1) / 2
                x0 = mid - 2
                x1 = mid + 2
            }
            return GapRange(lo: lo, hi: hi, x0: x0, x1: x1, duration: scale.gaps[i - 1].duration)
        }
    }

    // MARK: Drawing

    private func drawTracks(_ ctx: GraphicsContext, size: CGSize, lanes: [AnatomyLane]) {
        let w = size.width
        let lh = Self.laneHeight
        // Idle gaps: a diagonal hatch across all lanes, as CSS
        // `repeating-linear-gradient(135deg, line 0 3px, transparent 3px 7px)`:
        // 3 pt stripes every 7 pt, measured across the stripes.
        for g in gapRanges(w) where g.x1 >= 0 && g.x0 <= w {
            let rect = CGRect(x: g.x0, y: 0, width: g.x1 - g.x0, height: size.height)
            var c = ctx
            c.clip(to: Path(rect))
            var hatch = Path()
            let step = 7 * CGFloat(2).squareRoot()
            var hx = g.x0 - size.height
            while hx < g.x1 + step {
                hatch.move(to: CGPoint(x: hx, y: size.height))
                hatch.addLine(to: CGPoint(x: hx + size.height, y: 0))
                hx += step
            }
            c.stroke(hatch, with: .color(Ink.hatch), lineWidth: 3)
        }
        var children: [String: [AnatomyLane]] = [:]
        for lane in lanes { if let p = lane.parent { children[p, default: []].append(lane) } }

        for (row, lane) in lanes.enumerated() {
            let y = CGFloat(row) * lh
            if row > 0 {
                ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: 1)), with: .color(Ink.line2))
            }
            // A dashed line through the model call track.
            var dash = Path()
            dash.move(to: CGPoint(x: 0, y: y + Self.dashY + 0.5))
            dash.addLine(to: CGPoint(x: w, y: y + Self.dashY + 0.5))
            ctx.stroke(dash, with: .color(Ink.line2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Where each subagent this lane started ran: a light box on the tools track.
            for child in children[lane.id] ?? [] {
                guard let s = child.startedAt, let e = child.endedAt else { continue }
                let x0 = x(s, w)
                let r = CGRect(x: x0, y: y + Self.toolTop, width: max(3, x(e, w) - x0), height: Self.toolHeight)
                guard r.maxX >= 0, r.minX <= w else { continue }
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.agent.opacity(0.10)))
                // The border is inside the box, as CSS `box-sizing: border-box`.
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5),
                           with: .color(Theme.agent.opacity(0.55)), lineWidth: 1)
            }

            // Model calls and tool calls.
            for e in lane.events where e.kind == .answer || e.kind == .tool || e.kind == .error {
                let x0 = x(e.start, w)
                let x1 = x(e.end, w)
                guard x1 >= -4, x0 <= w + 4 else { continue }
                switch e.kind {
                case .answer:
                    let r = CGRect(x: x0, y: y + Self.callTop, width: max(1.5, x1 - x0), height: Self.callHeight)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.modelCall))
                case .tool:
                    let r = CGRect(x: x0, y: y + Self.toolTop, width: max(2, x1 - x0), height: Self.toolHeight)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Palette.tool(e.tool)))
                    if e.isError {
                        // A failed call: a red line under it.
                        let u = CGRect(x: r.minX, y: r.maxY + 1.5, width: r.width, height: 2)
                        ctx.fill(Path(roundedRect: u, cornerRadius: 1), with: .color(Theme.bad))
                    }
                default:
                    let cy = y + Self.callTop + Self.callHeight / 2
                    ctx.fill(Path(ellipseIn: CGRect(x: x0 - 3, y: cy - 3, width: 6, height: 6)), with: .color(Theme.bad))
                }
            }

            // Compactions and prompts, on top.
            for e in lane.events where e.kind == .compact || e.kind == .prompt {
                let x0 = x(e.start, w)
                guard x0 >= -6, x0 <= w + 6 else { continue }
                if e.kind == .compact {
                    ctx.fill(Path(CGRect(x: x0 - 1, y: y, width: 2, height: lh)), with: .color(Theme.bad))
                } else {
                    let dot = CGRect(x: x0 - 3.5, y: y + 3, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Ink.bg))
                    ctx.fill(Path(ellipseIn: dot), with: .color(Theme.prompt))
                }
            }

            // The selected event: a call grows 2 pt up and down, then a 2 pt
            // ring of the background and a 1.5 pt dark ring around it.
            if let ref = selected, ref.lane == lane.id, lane.events.indices.contains(ref.index),
               let r = blockRect(lane.events[ref.index], row: row, width: w) {
                let e = lane.events[ref.index]
                let grows = e.kind == .tool || e.kind == .answer
                let shape = grows ? r.insetBy(dx: 0, dy: -2) : r
                let radius: CGFloat = grows ? 2 : shape.width / 2
                if grows {
                    ctx.fill(Path(roundedRect: shape, cornerRadius: radius), with: .color(Palette.event(e)))
                }
                ctx.stroke(Path(roundedRect: shape.insetBy(dx: -1, dy: -1), cornerRadius: radius + 1),
                           with: .color(Ink.bg), lineWidth: 2)
                ctx.stroke(Path(roundedRect: shape.insetBy(dx: -2.75, dy: -2.75), cornerRadius: radius + 2.75),
                           with: .color(Ink.text), lineWidth: 1.5)
            }
        }
    }

    /// The drawn shape of an event, in track coordinates.
    private func blockRect(_ e: AnatomyEvent, row: Int, width w: CGFloat) -> CGRect? {
        let y = CGFloat(row) * Self.laneHeight
        let x0 = x(e.start, w)
        let x1 = x(e.end, w)
        switch e.kind {
        case .answer: return CGRect(x: x0, y: y + Self.callTop, width: max(1.5, x1 - x0), height: Self.callHeight)
        case .tool: return CGRect(x: x0, y: y + Self.toolTop, width: max(2, x1 - x0), height: Self.toolHeight)
        case .prompt: return CGRect(x: x0 - 3.5, y: y + 3, width: 7, height: 7)
        case .compact: return CGRect(x: x0 - 1, y: y + 1, width: 2, height: Self.laneHeight - 2)
        case .error:
            let cy = y + Self.callTop + Self.callHeight / 2
            return CGRect(x: x0 - 3, y: cy - 3, width: 6, height: 6)
        }
    }

    /// Times below the track area, and each idle gap labeled at its place.
    private func drawAxis(_ ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        // Labels sit 7 pt from the top of the 28 pt row; the first and the
        // last are 0.4 % of the width from the ends.
        let top: CGFloat = 7
        let edge = w * 0.004
        let gaps = gapRanges(w)
        var taken: [CGRect] = []
        let measure = CGSize(width: 400, height: size.height)

        for g in gaps {
            let cx = (g.x0 + g.x1) / 2
            guard cx >= -40, cx <= w + 40 else { continue }
            let text = ctx.resolve(Text("idle \(shortDuration(g.duration))").font(.system(size: 11)).foregroundStyle(Ink.text3))
            let s = text.measure(in: measure)
            let left = min(max(cx - s.width / 2, 4), w - s.width - 4)
            let rect = CGRect(x: left, y: top, width: s.width, height: s.height)
            if taken.contains(where: { $0.insetBy(dx: -6, dy: 0).intersects(rect) }) { continue }
            taken.append(rect)
            ctx.draw(text, in: rect)
        }

        // Ticks about every 110 pt; with seconds when they are under 2 minutes apart.
        let count = max(2, Int(w / 110))
        let seconds = window.span * scale.shownSeconds / Double(count) < 120
        let pad = 0.5 / Double(max(w, 1)) * window.span * 8
        for i in 0 ... count {
            let v = Double(i) / Double(count)
            let pos = window.position(atView: v)
            if gaps.contains(where: { pos >= $0.lo - pad && pos <= $0.hi + pad }) { continue }
            guard let d = scale.date(at: pos) else { continue }
            let time = seconds ? d.formatted(.dateTime.hour().minute().second()) : d.formatted(date: .omitted, time: .shortened)
            let text = ctx.resolve(Text(time).font(.system(size: 11)).foregroundStyle(Ink.text3).monospacedDigit())
            let s = text.measure(in: measure)
            let px = CGFloat(v) * w
            let left: CGFloat = i == 0 ? edge : i == count ? w - s.width - edge : px - s.width / 2
            let rect = CGRect(x: left, y: top, width: s.width, height: s.height)
            if taken.contains(where: { $0.insetBy(dx: -8, dy: 0).intersects(rect) }) { continue }
            taken.append(rect)
            ctx.draw(text, in: rect)
        }
    }

    // MARK: Hit test

    /// The event under a point. Above the dashed line: prompts, compactions
    /// and API errors first, then model calls. Below it: tools first, then
    /// compactions.
    private func hit(_ p: CGPoint, width: CGFloat, lanes: [AnatomyLane]) -> EventRef? {
        guard p.y >= 0 else { return nil }
        let row = Int(p.y / Self.laneHeight)
        guard lanes.indices.contains(row) else { return nil }
        let lane = lanes[row]
        let top = p.y - CGFloat(row) * Self.laneHeight < Self.splitY
        var best: (index: Int, rank: Int, dist: CGFloat)?
        for (i, e) in lane.events.enumerated() {
            let rank: Int? = switch (e.kind, top) {
            case (.prompt, true), (.compact, _), (.error, true): 0
            case (.answer, true), (.tool, false): 1
            default: nil
            }
            guard let rank else { continue }
            let pointLike = e.kind == .prompt || e.kind == .compact || e.kind == .error
            let x0 = x(e.start, width) - (pointLike ? 5 : 2)
            let x1 = max(x(e.end, width), x(e.start, width) + 2) + (pointLike ? 5 : 2)
            guard p.x >= x0, p.x <= x1 else { continue }
            let dist = abs(p.x - (x0 + x1) / 2)
            if best == nil || rank < best!.rank || (rank == best!.rank && dist < best!.dist) {
                best = (i, rank, dist)
            }
        }
        return best.map { EventRef(lane: lane.id, index: $0.index) }
    }

    // MARK: Callout

    /// The hovered event, or else the selected one, in a dark callout under it.
    @ViewBuilder
    private func calloutLayer(_ lanes: [AnatomyLane]) -> some View {
        GeometryReader { g in
            let trackX = Self.labelWidth + 1
            let boxWidth = g.size.width
            let width = boxWidth - trackX
            if let ref = hover ?? selected,
               let row = lanes.firstIndex(where: { $0.id == ref.lane }),
               lanes[row].events.indices.contains(ref.index),
               let r = blockRect(lanes[row].events[ref.index], row: row, width: width),
               r.maxX >= 0, r.minX <= width {
                let e = lanes[row].events[ref.index]
                let cx = trackX + min(max(r.midX, 0), width)
                // As on the board: a tool call ends at 40 pt, the arrow's box
                // starts at 50 pt, and the callout 5 pt lower, under the arrow.
                let ty = r.maxY + 10
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2).fill(Ink.callout)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(45))
                        .offset(x: cx - 5, y: ty)
                    EventCallout(lane: lanes[row], event: e)
                        .alignmentGuide(.leading) { d in -min(max(cx - 27, 0), max(0, boxWidth - d.width)) }
                        .alignmentGuide(.top) { _ in -(ty + 5) }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small bordered button, as in the timeline header.
private struct ZoomButtonStyle: ButtonStyle {
    var width: CGFloat? = 26

    func makeBody(configuration: Configuration) -> some View {
        ZoomButton(configuration: configuration, width: width)
    }

    private struct ZoomButton: View {
        let configuration: ButtonStyleConfiguration
        let width: CGFloat?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Ink.text)
                .padding(.horizontal, width == nil ? 10 : 0)
                .frame(width: width, height: 24)
                .background(configuration.isPressed ? Ink.soft : Ink.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.line))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

/// The dark callout: what the event did, its time, tokens and errors.
private struct EventCallout: View {
    let lane: AnatomyLane
    let event: AnatomyEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                // The dark mode colour, which reads better on the dark callout
                // (Bash: #2DD4BF, as on the board).
                RoundedRectangle(cornerRadius: 2).fill(Palette.event(event)).frame(width: 9, height: 9)
                    .environment(\.colorScheme, .dark)
                title
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(facts)
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if lane.id != "main" || event.error != nil {
                Text([event.error.map { "Error: \($0)" }, lane.id != "main" ? "in \(lane.name)" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.leading, 19)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Ink.callout, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 9, y: 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var title: some View {
        let e = event
        switch e.kind {
        case .tool:
            let input = e.command ?? e.text ?? ""
            if e.tool == "Bash", !input.isEmpty {
                Text(input).font(.system(size: 11.5, design: .monospaced))
            } else {
                HStack(spacing: 6) {
                    Text(e.label).fontWeight(.medium)
                    if !input.isEmpty { Text(input).font(.system(size: 11.5, design: .monospaced)) }
                }
            }
        case .answer:
            Text([e.label, shortModel(e.model)].compactMap { $0 }.joined(separator: " · ")).fontWeight(.medium)
        case .prompt:
            Text(e.text.map { "“\($0)”" } ?? "Prompt")
        case .compact, .error:
            Text(e.text ?? e.label).fontWeight(.medium)
        }
    }

    private var facts: String {
        let e = event
        var parts = [shortDuration(e.duration)]
        switch e.kind {
        case .answer:
            if let c = e.contextTokens { parts.append("context \(Format.tokens(c))") }
            if let u = e.usage { parts.append("output \(Format.tokens(u.outputTokens))") }
            if let c = e.costMicros { parts.append(Format.dollars(c)) }
        case .tool:
            if let t = e.addedTokens { parts.append("+\(Format.tokens(t)) to context") }
            if e.isError { parts.append(e.refusal != nil ? "refused" : "failed") }
        case .prompt:
            parts = []
            if let t = e.addedTokens { parts.append("+\(Format.tokens(t)) to context") }
        case .compact:
            if let t = e.addedTokens { parts.append("+\(Format.tokens(t)) to context") }
        case .error:
            break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Legend

/// Rows that wrap, like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        let maxX = frames.map(\.maxX).max() ?? 0
        let maxY = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? maxX, height: maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        for (frame, view) in zip(place(subviews, width: bounds.width), subviews) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return frames
    }
}

private struct AnatomyLegend: View {
    let anatomy: Anatomy

    var body: some View {
        FlowLayout {
            item("Model call") { RoundedRectangle(cornerRadius: 2).fill(Theme.modelCall).frame(width: 12, height: 6) }
            ForEach(toolGroups, id: \.label) { g in
                item(g.label) { RoundedRectangle(cornerRadius: 2).fill(g.color).frame(width: 12, height: 8) }
            }
            if anatomy.lanes.count > 1 {
                item("Subagent running") {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.agent.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.agent.opacity(0.6)))
                        .frame(width: 12, height: 8)
                }
            }
            item("Your prompt") { Circle().fill(Theme.prompt).frame(width: 7, height: 7) }
            item("Compaction") { Rectangle().fill(Theme.bad).frame(width: 2, height: 10) }
            item("Failed call") { RoundedRectangle(cornerRadius: 1).fill(Theme.bad).frame(width: 12, height: 2) }
            item("Idle gap, shortened") {
                RoundedRectangle(cornerRadius: 2).fill(Ink.track)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Ink.line))
                    .frame(width: 12, height: 8)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Ink.text2)
        .padding(.leading, 2)
    }

    private func item(_ name: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 5) {
            swatch()
            Text(name).lineLimit(1)
        }
    }

    /// One entry per tool color: `Edit, Write`; tools without their own color are `Other tools`.
    private var toolGroups: [(label: String, color: Color)] {
        var order: [String] = []
        var names: [String: [String]] = [:]
        var colors: [String: Color] = [:]
        for t in anatomy.tools {
            let th = Theme.tool(t.tool)
            if names[th.symbol] == nil {
                order.append(th.symbol)
                colors[th.symbol] = th.color
            }
            names[th.symbol, default: []].append(t.tool)
        }
        let other = Theme.tool("").symbol
        return order.map { key in
            let n = names[key] ?? []
            let label = key == other && n.count > 1 ? "Other tools" : n.prefix(2).joined(separator: ", ")
            return (label, colors[key] ?? Theme.otherTool)
        }
    }
}

// MARK: - Tools

private struct ToolCards: View {
    @Environment(AppModel.self) private var model
    let anatomy: Anatomy
    @State private var agentList = false

    static let agentTools: Set<String> = ["Agent", "Task"]

    /// The subagents in tree order; a click opens one alone in Chat.
    private var subagentList: some View {
        let lanes = anatomy.lanesInTreeOrder.filter { $0.id != "main" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lanes) { lane in
                    Button {
                        agentList = false
                        model.chatLane = lane.id
                        model.windowTab = .chat
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.agent).frame(width: 3, height: 14)
                            Text(lane.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 12)
                            Text([shortModel(lane.model), Format.dollars(lane.costMicros)].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(Ink.text3).monospacedDigit()
                        }
                        .font(.system(size: 12.5))
                        .padding(.leading, 8 + CGFloat(max(0, anatomy.depth(of: lane) - 1)) * 12)
                        .padding(.trailing, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                }
            }
            .padding(4)
        }
        .frame(width: 380)
        .frame(maxHeight: 420)
    }

    var body: some View {
        let added = addedTokens
        let biggest = anatomy.tools.max { (added[$0.tool] ?? 0) < (added[$1.tool] ?? 0) }
        let maxAdded = biggest.flatMap { added[$0.tool] } ?? 0
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools").font(.system(size: 13, weight: .semibold))
            if anatomy.tools.isEmpty {
                Text("No tool calls.").font(.system(size: 12)).foregroundStyle(Ink.text3)
            } else {
                AutoFitGrid(minWidth: 170, spacing: 10) {
                    ForEach(anatomy.tools) { t in
                        if Self.agentTools.contains(t.tool), anatomy.lanes.count > 1 {
                            // A click lists the subagents; one opens alone in Chat.
                            Button { agentList = true } label: {
                                card(t, added: added[t.tool] ?? 0, maxAdded: maxAdded).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show the subagents, to open one in Chat")
                            .popover(isPresented: $agentList, arrowEdge: .bottom) { subagentList }
                        } else {
                            card(t, added: added[t.tool] ?? 0, maxAdded: maxAdded)
                        }
                    }
                }
                if maxAdded > 0, let name = biggest?.tool {
                    Text("Bar: tokens the tool's results added to the context, compared with \(name).")
                        .font(.system(size: 11)).foregroundStyle(Ink.text3)
                }
            }
        }
    }

    /// Tokens each tool's results added to the context, over all lanes.
    private var addedTokens: [String: UInt64] {
        var out: [String: UInt64] = [:]
        for lane in anatomy.lanes {
            for e in lane.events where e.kind == .tool {
                out[e.tool ?? "Tool", default: 0] += e.addedTokens ?? 0
            }
        }
        return out
    }

    private func card(_ t: ToolStat, added: UInt64, maxAdded: UInt64) -> some View {
        let th = Theme.tool(t.tool)
        let time = shortDuration(Double(t.totalMs) / 1000)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolTile(tool: t.tool)
                Text(t.tool).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(t.calls)").font(.system(size: 20, weight: .semibold)).monospacedDigit()
            }
            Bar(value: maxAdded > 0 ? Double(added) / Double(maxAdded) : 0, color: th.color)
            HStack(spacing: 0) {
                Text(added > 0 ? "\(time) · +\(Format.tokens(added)) · " : "\(time) · ")
                if t.errors > 0 {
                    Text(plural(Int(t.errors), "error")).foregroundStyle(Theme.bad)
                } else {
                    Text("no errors")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Ink.text2)
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help("\(t.tool): \(t.calls) calls, \(t.errors) errors, \(Format.duration(Double(t.totalMs) / 1000)) in total, returned \(Format.bytes(t.resultBytes)), added \(Format.tokens(added)) tokens to the context. Time adds up the time from each call to its result; calls that ran in parallel add up too.")
    }
}

/// The 28 pt icon of a tool card: a tinted square with 7 pt corners.
private struct ToolTile: View {
    let tool: String

    var body: some View {
        let th = Theme.tool(tool)
        // Read's yellow is too light for a glyph: the board uses #A16207 for it.
        let glyph = th.symbol == "doc.text" ? Theme.dynamic(0xA16207, 0xEAB308) : th.color
        Image(systemName: th.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(glyph)
            .frame(width: 28, height: 28)
            .background(th.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

/// A 4 pt bar on a track, with 2 pt corners.
private struct Bar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Ink.track)
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(width: max(0, g.size.width * min(1, value)))
            }
        }
        .frame(height: 4)
    }
}

/// A grid like CSS `repeat(auto-fit, minmax(minWidth, 1fr))`: as many
/// columns as fit, but never more than there are items, so a few items
/// share the whole width. Each row is as tall as its tallest item.
private struct AutoFitGrid: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat

    private func columns(_ width: CGFloat, _ count: Int) -> Int {
        let fit = max(1, Int((width + spacing) / (minWidth + spacing)))
        return max(1, min(fit, count))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (cols: Int, cell: CGFloat, heights: [CGFloat]) {
        let cols = columns(width, subviews.count)
        let cell = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let row = subviews[start ..< min(start + cols, subviews.count)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0)
        }
        return (cols, cell, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        let width = proposal.width ?? (minWidth * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1)))
        let r = rows(subviews, width: width)
        let height = r.heights.reduce(0, +) + spacing * CGFloat(max(0, r.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        let r = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in r.heights.enumerated() {
            for col in 0 ..< r.cols {
                let i = row * r.cols + col
                guard i < subviews.count else { break }
                let x = bounds.minX + CGFloat(col) * (r.cell + spacing)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: r.cell, height: height))
            }
            y += height + spacing
        }
    }
}

// MARK: - Turns

/// Each prompt with what it caused; click a turn to see each call.
private struct TurnList: View {
    let anatomy: Anatomy
    @Binding var selected: EventRef?
    @State private var open: Set<String> = []

    var body: some View {
        let maxCost = anatomy.turns.map(\.totalCostMicros).max() ?? 0
        let mixes = toolMixes
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Turns").font(.system(size: 13, weight: .semibold))
                Text("One turn: your prompt and all the work until the next one.")
                    .font(.system(size: 12)).foregroundStyle(Ink.text3)
            }
            .padding(.bottom, 6)
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(anatomy.turns) { turn in
                    let isOpen = open.contains(turn.id)
                    TurnRow(turn: turn, mix: mixes[turn.id] ?? [], maxCost: maxCost, isOpen: isOpen) {
                        if isOpen { open.remove(turn.id) } else { open.insert(turn.id) }
                    }
                    if isOpen {
                        TurnEvents(anatomy: anatomy, turn: turn, selected: $selected)
                            .padding(.leading, 54)
                            .padding(.trailing, 12)
                            .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    /// Tool calls of the main lane in each turn, by tool, the most first.
    private var toolMixes: [String: [(tool: String, count: Int)]] {
        guard let main = anatomy.lane("main") else { return [:] }
        var counts: [String: [String: Int]] = [:]
        for turn in anatomy.turns {
            for i in anatomy.mainEventIndices(in: turn) where main.events[i].kind == .tool {
                counts[turn.id, default: [:]][main.events[i].tool ?? "Tool", default: 0] += 1
            }
        }
        return counts.mapValues { byTool in
            byTool.map { (tool: $0.key, count: $0.value) }.sorted { ($0.count, $1.tool) > ($1.count, $0.tool) }
        }
    }
}

private struct TurnRow: View {
    let turn: Turn
    let mix: [(tool: String, count: Int)]
    let maxCost: UInt64
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Text(turn.index == 0 ? "–" : "\(turn.index)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ok)
                .frame(width: 26, height: 26)
                .background(Theme.ok.opacity(0.11), in: Circle())
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.prompt.isEmpty ? "Before the first prompt" : turn.prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(turn.prompt.isEmpty ? Ink.text3 : Ink.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(caption).font(.system(size: 11.5)).foregroundStyle(Ink.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                MixBar(mix: mix).frame(height: 6)
                Text(mixText).font(.system(size: 11)).foregroundStyle(Ink.text3).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 150)
            .help(mix.map { "\($0.count) \($0.tool)" }.joined(separator: ", "))
            VStack(alignment: .trailing, spacing: 4) {
                Text(Format.dollars(turn.totalCostMicros)).font(.system(size: 13, weight: .semibold))
                Bar(value: maxCost > 0 ? Double(turn.totalCostMicros) / Double(maxCost) : 0, color: Ink.text)
            }
            .frame(width: 110)
            .help(costHelp)
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering || isOpen ? Ink.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Hide the calls of this turn" : "Show the calls of this turn")
    }

    private var caption: String {
        var parts = [turn.start.formatted(date: .omitted, time: .shortened), shortDuration(turn.duration),
                     plural(Int(turn.answers), "call")]
        if !turn.subagents.isEmpty { parts.append(plural(turn.subagents.count, "subagent")) }
        return parts.joined(separator: " · ")
    }

    private var mixText: String {
        guard !mix.isEmpty else { return "no tools" }
        var parts = mix.prefix(3).map { "\($0.count) \($0.tool)" }
        let rest = mix.dropFirst(3).reduce(0) { $0 + $1.count }
        if rest > 0 { parts.append("\(rest) other") }
        return parts.joined(separator: " · ")
    }

    private var costHelp: String {
        var s = "Main: \(Format.tokens(turn.usage.total)) tokens, \(Format.dollars(turn.costMicros))"
        if !turn.subagents.isEmpty {
            s += "\nSubagents: \(Format.tokens(turn.subagentUsage.total)) tokens, \(Format.dollars(turn.subagentCostMicros))"
        }
        return s
    }
}

/// The tool calls of a turn as one stacked bar: the four biggest tools, then the rest in grey.
private struct MixBar: View {
    let mix: [(tool: String, count: Int)]

    var body: some View {
        GeometryReader { g in
            let parts = segments
            let total = parts.reduce(0) { $0 + $1.count }
            let room = max(0, g.size.width - CGFloat(max(0, parts.count - 1)))
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.color)
                        .frame(width: total > 0 ? room * CGFloat(p.count) / CGFloat(total) : 0)
                }
            }
            .frame(width: g.size.width, alignment: .leading)
            // The parts fill the width; the track shows only for a turn with no tools.
            .background(parts.isEmpty ? Ink.track : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private var segments: [(color: Color, count: Int)] {
        var out = mix.prefix(4).map { (color: Palette.tool($0.tool), count: $0.count) }
        let rest = mix.dropFirst(4).reduce(0) { $0 + $1.count }
        if rest > 0 { out.append((Theme.otherTool.opacity(0.5), rest)) }
        return out
    }
}

/// The events of a turn's main lane; an Agent call opens to its subagent's events.
private struct TurnEvents: View {
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

private struct SubagentEvents: View {
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
                IconTile(symbol: Theme.tool("Agent").symbol, color: Theme.agent, size: 18)
                Text("Subagent: \(lane.name)").fontWeight(.medium)
                Text([shortDuration(lane.duration), "\(Format.tokens(lane.usage.total)) tokens",
                      "\(lane.toolCalls) tools", shortModel(lane.model)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(Ink.text3)
            }
            .font(.system(size: 12))
        }
        .padding(.leading, CGFloat(depth) * 18)
    }
}

private struct EventRow: View {
    let event: AnatomyEvent
    let depth: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let e = event
        HStack(spacing: 8) {
            Text(e.start.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(Ink.text3)
                .frame(width: 70, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Palette.event(e)).frame(width: 8, height: 8)
            Text(e.label).fontWeight(e.kind == .tool ? .medium : .regular).frame(width: 110, alignment: .leading).lineLimit(1)
            Text(e.command ?? e.text ?? "").lineLimit(1)
                .font(e.command != nil ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(e.kind == .answer ? Ink.text3 : Ink.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if e.isError { Text("error").foregroundStyle(Theme.bad) }
            Text(Format.duration(e.duration)).monospacedDigit().foregroundStyle(Ink.text3).frame(width: 70, alignment: .trailing)
            Text(tokens(e)).monospacedDigit().foregroundStyle(Ink.text3).frame(width: 150, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
        .padding(.leading, CGFloat(depth) * 18 + 4)
        .padding(.trailing, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
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

/// A list row that tints while the pointer is over it.
private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(hovering ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .onHover { hovering = $0 }
        }
    }
}
