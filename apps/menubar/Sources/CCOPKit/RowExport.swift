// What the right-click menu of a table row copies or saves as JSON. The keys
// and dates are as in the CLI's JSON (snake_case, RFC 3339).

import Foundation

public enum RowExport {
    /// One event of a lane; for a tool call also its whole input and output.
    public struct Call: Encodable, Sendable {
        public var sessionId: String
        public var lane: String
        public var laneName: String
        public var eventIndex: Int
        public var event: AnatomyEvent
        /// `ccop call`: the whole input and output.
        public var call: ToolCall?
        /// A prompt's whole text.
        public var text: String?
    }

    /// The Bash calls of one program.
    public struct Program: Encodable, Sendable {
        public var sessionId: String
        public var program: String
        public var calls: UInt64
        public var errors: UInt64
        public var costMicros: UInt64
        public var resultBytes: UInt64
        public var items: [Call]
    }

    /// One subagent with all its events.
    public struct Subagent: Encodable, Sendable {
        public var sessionId: String
        public var lane: AnatomyLane
        public var spend: LaneSpend?
    }

    public static func call(sessionID: String, lane: AnatomyLane, event: Int, call: ToolCall? = nil, text: String? = nil) -> Call {
        Call(sessionId: sessionID, lane: lane.id, laneName: lane.name, eventIndex: event, event: lane.events[event], call: call, text: text)
    }

    /// The items keep the order of the group. An item whose lane or event is
    /// gone is left out.
    public static func program(_ group: CommandGroup, in anatomy: Anatomy) -> Program {
        let items = group.items.compactMap { item -> Call? in
            guard let lane = anatomy.lane(item.lane), lane.events.indices.contains(item.event) else { return nil }
            return call(sessionID: anatomy.sessionId, lane: lane, event: item.event)
        }
        return Program(sessionId: anatomy.sessionId, program: group.group, calls: group.calls, errors: group.errors,
                       costMicros: group.costMicros, resultBytes: group.resultBytes, items: items)
    }

    public static func subagent(_ lane: AnatomyLane, in anatomy: Anatomy) -> Subagent {
        Subagent(sessionId: anatomy.sessionId, lane: lane, spend: anatomy.spend.lane(lane.id))
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .custom { path in SnakeKey(snake(path.last?.stringValue ?? "")) }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return try encoder.encode(value)
    }

    /// `ccop-1a2b3c4d-bash-sed.json`: safe in any folder, at most 40 characters of name.
    public static func fileName(sessionID: String, name: String) -> String {
        var slug = ""
        for c in name.lowercased() {
            if c.isASCII, c.isLetter || c.isNumber { slug.append(c) } else if !slug.isEmpty, !slug.hasSuffix("-") { slug.append("-") }
            if slug.count == 40 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let parts = ["ccop", String(sessionID.prefix(8)), slug].filter { !$0.isEmpty }
        return parts.joined(separator: "-") + ".json"
    }

    /// `toolUseId` → `tool_use_id`; `cacheWrite1HTokens` → `cache_write_1h_tokens`,
    /// the key the decoder reads into that name (see `TokenUsage`).
    static func snake(_ key: String) -> String {
        var out = ""
        var previous: Character?
        for c in key {
            if c.isUppercase {
                if previous?.isNumber != true { out.append("_") }
                out.append(contentsOf: c.lowercased())
            } else if c.isNumber {
                if previous?.isNumber != true { out.append("_") }
                out.append(c)
            } else {
                out.append(c)
            }
            previous = c
        }
        return out
    }

    private struct SnakeKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
