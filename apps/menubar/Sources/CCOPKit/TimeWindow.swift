import Foundation

/// The part of a timeline that is shown, as positions of a `TimeScale`
/// (0 is the first event, 1 the last). The whole timeline is `0...1`;
/// zoomed in 4×, it is a quarter of it, such as `0.5...0.75`.
public struct TimeWindow: Equatable, Sendable {
    public private(set) var lo: Double
    public private(set) var hi: Double

    /// The deepest zoom: a 1000th of the timeline.
    public static let minSpan = 0.001

    public init() {
        lo = 0
        hi = 1
    }

    /// A window from `lo` to `hi`, moved and shortened to fit `0...1`.
    public init(lo: Double, hi: Double) {
        self.init()
        set(lo: lo, span: hi - lo)
    }

    public var span: Double { hi - lo }
    /// 1 for the whole timeline, 4 for a quarter of it.
    public var zoom: Double { 1 / span }
    public var isWhole: Bool { lo <= 0 && hi >= 1 }

    /// A scale position as a part of the view's width: 0 is the left edge,
    /// 1 the right edge; outside `0...1` when it is not shown.
    public func view(_ position: Double) -> Double { (position - lo) / span }

    /// The scale position at a part of the view's width.
    public func position(atView v: Double) -> Double { lo + v * span }

    /// Zooms in (`factor` > 1) or out (< 1). The position at `anchor` (a part
    /// of the view's width) stays where it is on the screen.
    public mutating func zoom(by factor: Double, at anchor: Double = 0.5) {
        guard factor > 0, factor.isFinite else { return }
        let a = min(max(anchor, 0), 1)
        let fixed = position(atView: a)
        let span = min(max(span / factor, Self.minSpan), 1)
        set(lo: fixed - a * span, span: span)
    }

    /// Moves by a part of the view's width: 0.5 moves half a view later.
    public mutating func pan(by fraction: Double) {
        guard fraction.isFinite else { return }
        set(lo: lo + fraction * span, span: span)
    }

    /// Moves the window so that `position` is in the middle, when it is not shown now.
    public mutating func reveal(_ position: Double) {
        let v = view(position)
        guard v < 0 || v > 1 else { return }
        set(lo: position - span / 2, span: span)
    }

    private mutating func set(lo: Double, span: Double) {
        let span = min(max(span, Self.minSpan), 1)
        let lo = min(max(lo, 0), 1 - span)
        self.lo = lo
        hi = lo + span
    }
}
