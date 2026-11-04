// Tokens and cost of a whole session (main and subagents) over time, in equal
// periods: where the consumption was biggest. It comes from the model calls of
// the anatomy, so it adds up to the session's totals.

import Foundation

public struct Consumption: Equatable, Sendable {
    /// One model call.
    public struct Call: Equatable, Sendable {
        public var lane: String
        public var at: Date
        public var usage: TokenUsage
        public var costMicros: UInt64

        public init(lane: String, at: Date, usage: TokenUsage, costMicros: UInt64) {
            self.lane = lane
            self.at = at
            self.usage = usage
            self.costMicros = costMicros
        }
    }

    /// What one lane used in a period.
    public struct LaneShare: Equatable, Sendable, Identifiable {
        public var id: String
        public var usage = TokenUsage()
        public var costMicros: UInt64 = 0
    }

    public struct Bucket: Equatable, Sendable, Identifiable {
        public var start: Date
        public var end: Date
        public var usage = TokenUsage()
        public var costMicros: UInt64 = 0
        public var calls = 0
        /// The lanes with calls in this period, most tokens first.
        public var lanes: [LaneShare] = []
        public var id: Date { start }
    }

    /// In time order, with no holes: a period without calls is an empty bucket.
    public var buckets: [Bucket]
    /// The length of one period, in seconds.
    public var step: TimeInterval
    public var usage: TokenUsage
    public var costMicros: UInt64

    /// The period lengths to choose from: they read well on a clock.
    private static let steps: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 604_800]

    /// `maxBuckets` limits the bars, so a bar stays wide enough to see.
    /// `timeZone`: periods start at round times of this clock (20:15, not 20:13).
    public init(calls: [Call], maxBuckets: Int = 60, timeZone: TimeZone = .current) {
        usage = calls.reduce(TokenUsage()) { $0 + $1.usage }
        costMicros = calls.reduce(0) { $0 + $1.costMicros }
        guard let first = calls.map(\.at).min(), let last = calls.map(\.at).max() else {
            buckets = []
            step = Self.steps[0]
            return
        }
        let span = last.timeIntervalSince(first)
        let limit = TimeInterval(max(1, maxBuckets - 1))
        let step = Self.steps.first { span / $0 <= limit } ?? (span / limit).rounded(.up)
        let offset = TimeInterval(timeZone.secondsFromGMT(for: first))
        func index(_ date: Date) -> Int { Int(((date.timeIntervalSince1970 + offset) / step).rounded(.down)) }
        let base = index(first)
        var out = (0 ... index(last) - base).map { i -> Bucket in
            let start = Date(timeIntervalSince1970: TimeInterval(base + i) * step - offset)
            return Bucket(start: start, end: start.addingTimeInterval(step))
        }
        var lanes = [[String: LaneShare]](repeating: [:], count: out.count)
        for call in calls {
            let i = index(call.at) - base
            out[i].usage = out[i].usage + call.usage
            out[i].costMicros += call.costMicros
            out[i].calls += 1
            var share = lanes[i][call.lane] ?? LaneShare(id: call.lane)
            share.usage = share.usage + call.usage
            share.costMicros += call.costMicros
            lanes[i][call.lane] = share
        }
        for i in out.indices {
            out[i].lanes = lanes[i].values.sorted { ($0.usage.total, $1.id) > ($1.usage.total, $0.id) }
        }
        buckets = out
        self.step = step
    }

    /// The position of the period with the most tokens; the first of equals.
    /// Nil when no tokens were used.
    public var biggest: Int? {
        var best: Int?
        for i in buckets.indices where buckets[i].usage.total > (best.map { buckets[$0].usage.total } ?? 0) { best = i }
        return best
    }

    /// A number of tokens as a part of the session's tokens, 0 to 1.
    public func share(_ tokens: UInt64) -> Double {
        usage.total == 0 ? 0 : Double(tokens) / Double(usage.total)
    }

    /// The length of one period in words: `15 min`, `2 h`, `1 day`.
    public var stepText: String {
        if step < 3600 { return "\(Int(step / 60)) min" }
        if step < 86400 { return "\(Int(step / 3600)) h" }
        let days = Int(step / 86400)
        return days == 1 ? "1 day" : "\(days) days"
    }
}

public extension Anatomy {
    /// All model calls of the session, in all lanes, over time.
    func consumption(maxBuckets: Int = 60, timeZone: TimeZone = .current) -> Consumption {
        var calls: [Consumption.Call] = []
        for lane in lanes {
            for e in lane.events where e.kind == .answer {
                if let usage = e.usage {
                    calls.append(Consumption.Call(lane: lane.id, at: e.start, usage: usage, costMicros: e.costMicros ?? 0))
                }
            }
        }
        return Consumption(calls: calls, maxBuckets: maxBuckets, timeZone: timeZone)
    }
}
