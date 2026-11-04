import Foundation

/// What a chart's side panel shows: the value under the pointer, or the value
/// the user chose with a click. A chosen value stays when the pointer moves
/// away, so the pointer can reach the panel. A click on it lets it go.
public struct ChartPick: Equatable, Sendable {
    public private(set) var hovered: Int?
    public private(set) var pinned: Int?
    /// While the mouse button is down: where it went down, and what was chosen before.
    private var press: (start: Int, before: Int?, moved: Bool)?

    public init() {}

    public func shown(or fallback: Int) -> Int { pinned ?? hovered ?? fallback }

    public mutating func hover(_ value: Int?) { hovered = value }

    /// The button went down, or the pointer moved with the button down.
    public mutating func drag(to value: Int) {
        if var p = press {
            if value != p.start { p.moved = true }
            press = p
        } else {
            press = (value, pinned, false)
        }
        pinned = value
    }

    /// The button went up.
    public mutating func release() {
        if let p = press, !p.moved, p.before == p.start { pinned = nil }
        press = nil
    }

    public static func == (a: ChartPick, b: ChartPick) -> Bool {
        a.hovered == b.hovered && a.pinned == b.pinned
    }
}
