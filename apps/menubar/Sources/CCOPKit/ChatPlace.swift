// Places in the Chat tab: one event of one lane. The tables and the side
// panels of other tabs use these to go to the chat.

import Foundation

public struct ChatPlace: Equatable, Hashable, Sendable {
    public var lane: String
    public var event: Int

    public init(lane: String, event: Int) {
        self.lane = lane
        self.event = event
    }
}

public extension AnatomyEvent {
    /// `ccop call` can show this event: it is a tool call with an id.
    var hasFullCall: Bool { kind == .tool && toolUseId != nil }
}

public extension Anatomy {
    /// The `Agent` call that started a subagent, in the chat of its parent.
    /// Nil for the main lane and for a subagent with no known parent.
    func spawnPlace(of lane: AnatomyLane) -> ChatPlace? {
        guard let parentID = lane.parent, let parent = self.lane(parentID) else { return nil }
        let index = parent.events.firstIndex { e in
            e.kind == .tool && (e.agentId == lane.id || (lane.toolUseId != nil && e.toolUseId == lane.toolUseId))
        }
        return index.map { ChatPlace(lane: parent.id, event: $0) }
    }

    /// The first model call of a lane in a period.
    func firstCall(of laneID: String, in bucket: Consumption.Bucket) -> ChatPlace? {
        guard let lane = lane(laneID) else { return nil }
        let index = lane.events.firstIndex { e in
            e.kind == .answer && e.usage != nil && e.start >= bucket.start && e.start < bucket.end
        }
        return index.map { ChatPlace(lane: laneID, event: $0) }
    }

    /// Where a period starts in the chat: in the main lane when it has a call
    /// in the period, else in the lane that used the most tokens in it.
    func chatPlace(in bucket: Consumption.Bucket) -> ChatPlace? {
        firstCall(of: "main", in: bucket) ?? bucket.lanes.first.flatMap { firstCall(of: $0.id, in: bucket) }
    }
}

public extension Cause {
    /// The name people see: `Bash results`, `Your messages`.
    var title: String {
        switch kind {
        case .tool: "\(name) results"
        case .prompt: "Your messages"
        case .task: "Subagent tasks"
        case .compact: "Compaction"
        case .other: "Start"
        }
    }
}

public extension Spend {
    /// The cause made of one tool's results. A call with no tool name is
    /// `""` in `Anatomy.tools` and `Tool` in the causes.
    func cause(ofTool tool: String) -> Cause? {
        let name = tool.isEmpty ? "Tool" : tool
        return causes.first { $0.kind == .tool && $0.name == name }
    }

    /// The causes worth showing, the most cost first.
    var shownCauses: [Cause] {
        causes.filter { $0.costMicros > 0 || $0.count > 0 }
            .sorted { ($0.costMicros, $1.name) > ($1.costMicros, $0.name) }
    }
}
