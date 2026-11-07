// The Swift copy of `ccop anatomy <id> --json` (libs/core/src/anatomy.rs and
// context.rs). api/anatomy.example.json is decoded by AnatomyContractTests.

import Foundation

public struct Anatomy: Codable, Equatable, Sendable {
    public var sessionId: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var lanes: [AnatomyLane]
    public var turns: [Turn]
    public var tools: [ToolStat]
    public var contributors: [Contributor]
    public var spend: Spend

    public static func decode(_ data: Data) throws -> Anatomy {
        try Session.makeDecoder().decode(Anatomy.self, from: data)
    }

    public func lane(_ id: String) -> AnatomyLane? {
        lanes.first { $0.id == id }
    }

    /// How deep a lane is: 0 for main, 1 for a subagent main started, ...
    public func depth(of lane: AnatomyLane) -> Int {
        guard lane.id != "main" else { return 0 }
        var depth = 1
        var seen: Set<String> = [lane.id]
        var parent = lane.parent
        while let p = parent, p != "main", seen.insert(p).inserted, let next = self.lane(p) {
            depth += 1
            parent = next.parent
        }
        return depth
    }

    /// The lanes in tree order: each subagent after the lane that started it.
    public var lanesInTreeOrder: [AnatomyLane] {
        var out: [AnatomyLane] = []
        var added = Set<String>()
        func visit(_ lane: AnatomyLane) {
            guard added.insert(lane.id).inserted else { return }
            out.append(lane)
            for child in lanes where child.parent == lane.id { visit(child) }
        }
        lanes.filter { $0.id == "main" }.forEach(visit)
        // Subagents with no known parent, by start time.
        lanes.forEach(visit)
        return out
    }

    /// The events of the main lane in a turn: from its prompt to the next one.
    public func mainEvents(in turn: Turn) -> [AnatomyEvent] {
        guard let main = lane("main") else { return [] }
        return mainEventIndices(in: turn).map { main.events[$0] }
    }

    /// The same, as indices into the main lane's events.
    public func mainEventIndices(in turn: Turn) -> [Int] {
        guard let main = lane("main") else { return [] }
        let next = turns.first { $0.start > turn.start && $0.index > turn.index }?.start ?? .distantFuture
        return main.events.indices.filter { main.events[$0].start >= turn.start && main.events[$0].start < next }
    }

    public var compactions: Int {
        lanes.reduce(0) { $0 + $1.compactions }
    }
}

public struct AnatomyLane: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var parent: String?
    public var toolUseId: String?
    public var name: String
    public var agentType: String?
    public var model: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var usage: TokenUsage
    public var toolCalls: UInt64
    public var errors: UInt64
    public var events: [AnatomyEvent]
    public var context: [ContextPoint]
    /// What each call's context holds, item by item (`ContextContents`).
    public var contextItems: [ContextItem] = []

    public var duration: TimeInterval {
        guard let s = startedAt, let e = endedAt else { return 0 }
        return e.timeIntervalSince(s)
    }

    public var compactions: Int {
        events.filter { $0.kind == .compact }.count
    }

    /// The index of the first model call after event `index`: the call that a
    /// prompt or a tool result made run. Nil when the lane ends first.
    public func nextAnswer(after index: Int) -> Int? {
        guard index + 1 < events.count else { return nil }
        return events[(index + 1)...].firstIndex { $0.kind == .answer && $0.usage != nil }
    }

    /// The model calls (positions in `context`) that read what event `index`
    /// added: from the first call after it to the last one before the next
    /// compaction. Nil when no call read it.
    public func readingCalls(after index: Int) -> Range<Int>? {
        guard let first = context.firstIndex(where: { $0.event > index }) else { return nil }
        let compaction = events.indices.first { $0 > index && events[$0].kind == .compact } ?? Int.max
        let end = context[first...].firstIndex { $0.event > compaction } ?? context.count
        return first < end ? first ..< end : nil
    }

    /// The cost of the lane's most expensive model call, for bars.
    public var maxAnswerCost: UInt64 {
        events.filter { $0.kind == .answer }.compactMap(\.costMicros).max() ?? 0
    }
}

public enum EventKind: String, Codable, Sendable {
    /// `report`: a background subagent's report, or a message from another
    /// session; `agentId` is the sender.
    case prompt, answer, tool, compact, error, report
}

public struct AnatomyEvent: Codable, Equatable, Sendable {
    public var kind: EventKind
    public var start: Date
    public var end: Date
    public var text: String?
    public var model: String?
    public var usage: TokenUsage?
    public var tool: String?
    public var toolUseId: String?
    public var isError: Bool
    public var resultBytes: UInt64?
    public var agentId: String?
    public var contextTokens: UInt64?
    public var addedTokens: UInt64?
    /// Bash: the program it ran (`sed`, `node build.js context`).
    public var group: String?
    /// A failed tool call: the start of its error text.
    public var error: String?
    /// A command Claude Code refused to run in a worktree session: `loop`,
    /// `stdin`, `variable`, `xargs`, `git`, `complex`, `other`.
    public var refusal: String?
    /// Bash: the start of its command.
    public var command: String?
    /// Answer: the cost of the call. Prompt, tool or compaction: its part of the model call after it.
    public var costMicros: UInt64?
    /// Prompt, tool or compaction: its part of the tokens of the model call after it
    /// (input, cache write, cache read and output), split as `costMicros` is.
    public var paidTokens: UInt64?
    /// Compact: `auto` or `manual`.
    public var trigger: String?
    /// Compact: the size Claude Code gives for the context after it. The next
    /// call reads more: this does not count the system prompt and the tools.
    public var afterTokens: UInt64?

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// `Read`, `Model call`, `Prompt`, ...
    public var label: String {
        switch kind {
        case .prompt: "Prompt"
        case .answer: "Model call"
        case .tool: tool ?? "Tool"
        case .compact: "Compaction"
        case .error: "API error"
        case .report: "Subagent report"
        }
    }
}

public struct ContextPoint: Codable, Equatable, Sendable {
    public var at: Date
    public var event: Int
    public var total: UInt64
    public var parts: [ContextPart]
}

/// One prompt, tool result, answer's output, summary, `Start` or `Other` in
/// the context of the calls `firstCall...lastCall` (indexes into `context`).
/// The items of a call add up to its parts.
public struct ContextItem: Codable, Equatable, Sendable {
    /// Index into the lane's `events`; nil for `Start` and `Other`.
    public var event: Int?
    public var part: String
    public var firstCall: Int
    public var lastCall: Int
    public var tokens: UInt64

    public init(event: Int?, part: String, firstCall: Int, lastCall: Int, tokens: UInt64) {
        self.event = event
        self.part = part
        self.firstCall = firstCall
        self.lastCall = lastCall
        self.tokens = tokens
    }
}

public struct ContextPart: Codable, Equatable, Sendable {
    public var name: String
    public var tokens: UInt64
}

public struct Turn: Codable, Equatable, Sendable, Identifiable {
    public var index: UInt64
    public var start: Date
    public var end: Date
    public var prompt: String
    public var usage: TokenUsage
    public var subagentUsage: TokenUsage
    public var costMicros: UInt64
    public var subagentCostMicros: UInt64
    public var answers: UInt64
    public var toolCalls: UInt64
    public var subagents: [String]

    public var id: String { "\(index)-\(start.timeIntervalSince1970)" }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var totalCostMicros: UInt64 { costMicros + subagentCostMicros }
}

/// Where the cost of a session went (libs/core/src/spend.rs).
public struct Spend: Codable, Equatable, Sendable {
    public var costMicros: UInt64
    public var tokens: UInt64
    public var causes: [Cause]
    public var lanes: [LaneSpend]
    public var tips: [Tip]
    public var commands: [CommandGroup]
    public var errors: [ErrorGroup]

    public func lane(_ id: String) -> LaneSpend? {
        lanes.first { $0.lane == id }
    }

    /// A part of the session's cost, 0...1.
    public func share(_ micros: UInt64) -> Double {
        costMicros == 0 ? 0 : Double(micros) / Double(costMicros)
    }
}

public enum CauseKind: String, Codable, Sendable {
    case prompt, task, tool, compact, report, other
}

public struct Cause: Codable, Equatable, Sendable, Identifiable {
    public var kind: CauseKind
    public var name: String
    public var count: UInt64
    public var errors: UInt64
    public var modelCalls: Double
    public var costMicros: UInt64
    public var tokens: UInt64
    public var errorCostMicros: UInt64
    public var avgContext: UInt64
    public var addedTokens: UInt64
    /// The first paragraph of the tool's description; nil if the transcript has none.
    public var description: String? = nil
    /// For an MCP tool: the first sentence of its server's instructions, if they tell what the server is.
    public var serverDescription: String? = nil
    /// Every call behind this cause, in time order (`Cause.items` in spend.rs).
    public var items: [CallCost]
    public var id: String { "\(kind.rawValue) \(name)" }
}

public struct LaneSpend: Codable, Equatable, Sendable {
    public var lane: String
    public var costMicros: UInt64
    public var modelCalls: UInt64
    public var avgContext: UInt64
    public var maxContext: UInt64
    public var startContext: UInt64
    public var sonnetCostMicros: UInt64?
}

/// Bash calls that ran the same program.
public struct CommandGroup: Codable, Equatable, Sendable, Identifiable {
    public var group: String
    public var calls: UInt64
    public var errors: UInt64
    public var costMicros: UInt64
    public var resultBytes: UInt64
    public var example: String?
    /// Every call of the group, in the order of the lanes and their events.
    public var items: [CallCost]
    public var id: String { group }
}

/// One tool call (`lane`, index in its `events`) and its part of the model call after it.
public struct CallCost: Codable, Equatable, Sendable, Hashable {
    public var lane: String
    public var event: Int
    public var costMicros: UInt64
}

/// The full texts of one lane's events (`ccop chat`); the tokens are in the
/// anatomy, at the same event index.
public struct LaneChat: Codable, Equatable, Sendable {
    public var lane: String
    public var texts: [ChatText]

    public static func decode(_ data: Data) throws -> LaneChat {
        try Session.makeDecoder().decode(LaneChat.self, from: data)
    }

    /// The texts by event index.
    public var byEvent: [Int: ChatText] { Dictionary(texts.map { ($0.event, $0) }, uniquingKeysWith: { a, _ in a }) }
}

public struct ChatText: Codable, Equatable, Sendable {
    public var event: Int
    /// Prompt: its whole text. Answer: its text blocks.
    public var text: String?
    /// Answer: it had thinking blocks (their text is not saved; their tokens are in the output).
    public var thinking: Bool
    /// Tool: the input as the model wrote it.
    public var input: JSONValue?
    /// Tool: the start of its result.
    public var output: String?
    public var outputTruncated: Bool
}

/// One tool call in full (`ccop call`).
public struct ToolCall: Codable, Equatable, Sendable {
    public var toolUseId: String
    public var tool: String?
    public var input: JSONValue
    public var output: String?
    public var outputBytes: UInt64
    public var outputTruncated: Bool
    public var isError: Bool

    public static func decode(_ data: Data) throws -> ToolCall {
        try Session.makeDecoder().decode(ToolCall.self, from: data)
    }
}

/// Any JSON value, for a tool's input.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    /// Text for a person: a string as it is, other values as JSON with sorted keys.
    public var text: String {
        switch self {
        case .null: "null"
        case let .bool(b): b ? "true" : "false"
        case let .number(n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case let .string(s): s
        case .array, .object:
            (try? JSONEncoder.pretty.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// An input's fields for display: each field name and its text, a long
    /// text field (`command`, `content`, `prompt`) last.
    public var fields: [(name: String, text: String)] {
        guard case let .object(o) = self else { return [("input", text)] }
        let long: Set<String> = ["command", "content", "prompt", "new_string", "old_string"]
        let keys = o.keys.sorted { (long.contains($0) ? 1 : 0, $0) < (long.contains($1) ? 1 : 0, $1) }
        return keys.map { ($0, o[$0]!.text) }
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// Failed tool calls whose error text starts the same way.
public struct ErrorGroup: Codable, Equatable, Sendable, Identifiable {
    public var tool: String
    public var message: String
    public var count: UInt64
    public var costMicros: UInt64
    public var example: String?
    /// Why such calls fail and what to do, for errors ccop knows.
    public var cause: String?
    /// Worktree refusals are grouped by this kind (see `AnatomyEvent.refusal`).
    public var refusal: String?
    public var id: String { "\(tool) \(refusal ?? "") \(message)" }
}

public enum TipKind: String, Codable, Sendable {
    case manyCalls = "many_calls"
    case errors, model
    case bigContext = "big_context"
    case bigResults = "big_results"
    case cacheRewrites = "cache_rewrites"
    case lateCompaction = "late_compaction"
}

public struct Tip: Codable, Equatable, Sendable, Identifiable {
    public var kind: TipKind
    public var title: String
    public var detail: String
    public var costMicros: UInt64
    public var savingMicros: UInt64?
    /// The kind is not enough: Bash and Read calls give two `many_calls` tips.
    public var id: String { kind.rawValue + "|" + title }
}

public struct ToolStat: Codable, Equatable, Sendable, Identifiable {
    public var tool: String
    public var calls: UInt64
    public var errors: UInt64
    public var totalMs: UInt64
    public var resultBytes: UInt64
    public var id: String { tool }
}

public struct Contributor: Codable, Equatable, Sendable {
    public var lane: String
    public var event: Int
    public var tokens: UInt64
}

/// Maps time to a position from 0 to 1 along a timeline, with each idle gap
/// longer than `maxGap` shown as `gapWidth` seconds, so hours of waiting do
/// not squeeze the work into a few pixels.
public struct TimeScale: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var start: Date
        public var end: Date
        /// Where the segment starts, in shown seconds.
        public var offset: TimeInterval
    }

    public struct Gap: Equatable, Sendable {
        /// Position 0...1 of the middle of the gap.
        public var position: Double
        public var duration: TimeInterval
    }

    public private(set) var segments: [Segment] = []
    public private(set) var gaps: [Gap] = []
    public private(set) var shownSeconds: TimeInterval = 0

    public init(spans: [(Date, Date)], maxGap: TimeInterval = 120, gapWidth: TimeInterval = 30) {
        let sorted = spans.map { ($0.0, max($0.0, $0.1)) }.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for (s, e) in sorted {
            if let last = merged.last, s.timeIntervalSince(last.1) <= maxGap {
                merged[merged.count - 1].1 = max(last.1, e)
            } else {
                merged.append((s, e))
            }
        }
        var offset: TimeInterval = 0
        var gapOffsets: [(TimeInterval, TimeInterval)] = []
        for (i, (s, e)) in merged.enumerated() {
            if i > 0 {
                gapOffsets.append((offset + gapWidth / 2, s.timeIntervalSince(merged[i - 1].1)))
                offset += gapWidth
            }
            segments.append(Segment(start: s, end: e, offset: offset))
            offset += e.timeIntervalSince(s)
        }
        shownSeconds = max(offset, 1)
        gaps = gapOffsets.map { Gap(position: $0.0 / shownSeconds, duration: $0.1) }
    }

    /// 0...1 for a time; a time in a gap goes to the gap's middle.
    public func position(_ date: Date) -> Double {
        guard let first = segments.first else { return 0 }
        if date <= first.start { return 0 }
        for (i, seg) in segments.enumerated() {
            if date <= seg.end {
                if date >= seg.start { return (seg.offset + date.timeIntervalSince(seg.start)) / shownSeconds }
                // In the gap before this segment.
                let prev = segments[i - 1]
                let prevEnd = prev.offset + prev.end.timeIntervalSince(prev.start)
                return (prevEnd + (seg.offset - prevEnd) / 2) / shownSeconds
            }
        }
        return 1
    }

    /// The time at a position, inside a segment.
    public func date(at position: Double) -> Date? {
        let shown = position * shownSeconds
        // The tolerance: 120/220 * 220 is 119.99999999999999, not 120.
        for seg in segments.reversed() where shown >= seg.offset - 1e-6 {
            return min(seg.end, seg.start.addingTimeInterval(shown - seg.offset))
        }
        return segments.first?.start
    }

    /// Time spent in the segments, without the gaps.
    public var activeSeconds: TimeInterval {
        segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }
}
