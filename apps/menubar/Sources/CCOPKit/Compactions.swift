// The compactions of a session as table rows: one per `compact` event, in any
// lane, with the numbers the Overview shows.

import Foundation

public struct CompactionRow: Identifiable, Equatable, Sendable {
    public var place: ChatPlace
    public var laneName: String
    public var start: Date
    public var duration: TimeInterval
    /// `auto` or `manual`; nil when the transcript does not say.
    public var trigger: String?
    /// The context Claude Code gives for the moment before it.
    public var beforeTokens: UInt64
    /// The context Claude Code gives for the moment after it, without the
    /// system prompt and the tools.
    public var afterTokens: UInt64?
    /// What the next model call of the lane really read. Nil when the lane ends first.
    public var nextCallTokens: UInt64?
    /// Its part of the next model call. The call that writes the summary is
    /// not in the transcript, so this does not include that call.
    public var costMicros: UInt64

    public var id: ChatPlace { place }
}

public extension Anatomy {
    /// All compactions of the session, the earliest first.
    var compactionRows: [CompactionRow] {
        lanes.flatMap { lane in
            lane.events.indices.filter { lane.events[$0].kind == .compact }.map { i in
                let e = lane.events[i]
                return CompactionRow(place: ChatPlace(lane: lane.id, event: i), laneName: lane.name,
                                     start: e.start, duration: e.duration, trigger: e.trigger,
                                     beforeTokens: e.usage?.inputTokens ?? 0, afterTokens: e.afterTokens,
                                     nextCallTokens: lane.nextAnswer(after: i).flatMap { lane.events[$0].contextTokens },
                                     costMicros: e.costMicros ?? 0)
            }
        }
        .sorted { $0.start < $1.start }
    }

    /// `3 · 1 main · 2 in subagents`, or `3` when they are all in one kind of lane.
    var compactionSummary: String {
        let main = lane("main")?.compactions ?? 0
        let sub = compactions - main
        return main > 0 && sub > 0 ? "\(compactions) · \(main) main · \(sub) in subagents" : "\(compactions)"
    }
}
