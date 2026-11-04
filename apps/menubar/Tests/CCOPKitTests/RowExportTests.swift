import Foundation
import XCTest
@testable import CCOPKit

final class RowExportTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ kind: EventKind, tool: String? = nil, id: String? = nil, agent: String? = nil, at: TimeInterval = 0, usage: TokenUsage? = nil) -> AnatomyEvent {
        let d = t.addingTimeInterval(at)
        return AnatomyEvent(kind: kind, start: d, end: d, usage: usage, tool: tool, toolUseId: id, isError: false, agentId: agent)
    }

    private func lane(_ id: String, parent: String? = nil, useID: String? = nil, _ events: [AnatomyEvent]) -> AnatomyLane {
        AnatomyLane(id: id, parent: parent, toolUseId: useID, name: id == "main" ? "Main session" : "Helper \(id)",
                    usage: TokenUsage(), toolCalls: 0, errors: 0, events: events, context: [])
    }

    private func anatomy(_ lanes: [AnatomyLane], commands: [CommandGroup] = []) -> Anatomy {
        Anatomy(sessionId: "1a2b3c4d-5555", lanes: lanes, turns: [], tools: [], contributors: [],
                spend: Spend(costMicros: 0, tokens: 0, causes: [], lanes: [], tips: [], commands: commands, errors: []))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testKeysAreSnakeCaseAsTheDecoderReadsThem() throws {
        XCTAssertEqual(RowExport.snake("toolUseId"), "tool_use_id")
        XCTAssertEqual(RowExport.snake("cacheWrite1HTokens"), "cache_write_1h_tokens")
        XCTAssertEqual(RowExport.snake("lane"), "lane")
        let usage = TokenUsage(inputTokens: 1, cacheWriteTokens: 2, cacheWrite1HTokens: 3, cacheReadTokens: 4, outputTokens: 5, requests: 6)
        let back = try Session.makeDecoder().decode(TokenUsage.self, from: RowExport.encode(usage))
        XCTAssertEqual(back, usage)
    }

    func testAnEventComesBackTheSameWithItsDate() throws {
        let e = event(.tool, tool: "Read", id: "t1", at: 5)
        let back = try Session.makeDecoder().decode(AnatomyEvent.self, from: RowExport.encode(e))
        XCTAssertEqual(back, e)
    }

    func testACallHasItsPlaceAndItsWholeOutputAndKeepsInputKeys() throws {
        let l = lane("main", [event(.prompt), event(.tool, tool: "Read", id: "t1")])
        let full = ToolCall(toolUseId: "t1", tool: "Read", input: .object(["filePath": .string("a.txt"), "old_string": .string("x")]),
                            output: "hello", outputBytes: 5, outputTruncated: false, isError: false)
        let o = try object(RowExport.encode(RowExport.call(sessionID: "s1", lane: l, event: 1, call: full)))
        XCTAssertEqual(o["session_id"] as? String, "s1")
        XCTAssertEqual(o["lane"] as? String, "main")
        XCTAssertEqual(o["lane_name"] as? String, "Main session")
        XCTAssertEqual(o["event_index"] as? Int, 1)
        let call = try XCTUnwrap(o["call"] as? [String: Any])
        XCTAssertEqual(call["output"] as? String, "hello")
        // The names in a tool's input are the tool's: they do not change.
        let input = try XCTUnwrap(call["input"] as? [String: Any])
        XCTAssertEqual(Set(input.keys), ["filePath", "old_string"])
    }

    func testAPromptHasItsWholeTextAndNoCall() throws {
        let l = lane("main", [event(.prompt)])
        let o = try object(RowExport.encode(RowExport.call(sessionID: "s1", lane: l, event: 0, text: "the whole prompt")))
        XCTAssertEqual(o["text"] as? String, "the whole prompt")
        XCTAssertNil(o["call"])
    }

    func testAProgramListsItsCallsAndLeavesOutACallThatIsGone() throws {
        let a = anatomy([lane("main", [event(.tool, tool: "Bash", id: "t1")])])
        let group = CommandGroup(group: "sed", calls: 2, errors: 1, costMicros: 70, resultBytes: 9,
                                 items: [CallCost(lane: "main", event: 0, costMicros: 30), CallCost(lane: "main", event: 7, costMicros: 40)])
        let p = RowExport.program(group, in: a)
        XCTAssertEqual(p.program, "sed")
        XCTAssertEqual(p.items.map(\.eventIndex), [0])
        XCTAssertEqual(try object(RowExport.encode(p))["cost_micros"] as? Int, 70)
    }

    func testASubagentHasItsEventsAndSpend() throws {
        let sub = lane("a1", parent: "main", [event(.prompt), event(.answer)])
        var a = anatomy([lane("main", []), sub])
        a.spend.lanes = [LaneSpend(lane: "a1", costMicros: 12, modelCalls: 1, avgContext: 0, maxContext: 0, startContext: 0)]
        let o = try object(RowExport.encode(RowExport.subagent(sub, in: a)))
        XCTAssertEqual(((o["lane"] as? [String: Any])?["events"] as? [Any])?.count, 2)
        XCTAssertEqual((o["spend"] as? [String: Any])?["cost_micros"] as? Int, 12)
    }

    func testAFileNameIsSafeAndShort() {
        XCTAssertEqual(RowExport.fileName(sessionID: "1a2b3c4d-5555", name: "Bash sed"), "ccop-1a2b3c4d-bash-sed.json")
        XCTAssertEqual(RowExport.fileName(sessionID: "1a2b3c4d-5555", name: "../a/b: c?"), "ccop-1a2b3c4d-a-b-c.json")
        XCTAssertEqual(RowExport.fileName(sessionID: "1a2b3c4d", name: "///"), "ccop-1a2b3c4d.json")
        XCTAssertEqual(RowExport.fileName(sessionID: "1", name: String(repeating: "x", count: 99)), "ccop-1-\(String(repeating: "x", count: 40)).json")
    }

    func testASpawnPlaceIsTheAgentCallInTheParent() {
        let sub = lane("a1", parent: "main", useID: "t9", [event(.prompt)])
        let byAgent = lane("a2", parent: "main", [event(.prompt)])
        let orphan = lane("a3", parent: "gone", [event(.prompt)])
        let main = lane("main", [event(.prompt), event(.tool, tool: "Agent", id: "t9"), event(.tool, tool: "Agent", id: "t8", agent: "a2")])
        let a = anatomy([main, sub, byAgent, orphan])
        XCTAssertEqual(a.spawnPlace(of: sub), ChatPlace(lane: "main", event: 1))
        XCTAssertEqual(a.spawnPlace(of: byAgent), ChatPlace(lane: "main", event: 2))
        XCTAssertNil(a.spawnPlace(of: orphan))
        XCTAssertNil(a.spawnPlace(of: main))
    }

    func testOnlyAToolCallWithAnIdHasAFullCall() {
        XCTAssertTrue(event(.tool, tool: "Read", id: "t1").hasFullCall)
        XCTAssertFalse(event(.tool, tool: "Read").hasFullCall)
        XCTAssertFalse(event(.prompt).hasFullCall)
    }

    func testAPeriodStartsInMainWhenMainHasACallElseInTheBiggestLane() {
        let used = TokenUsage(inputTokens: 1)
        let main = lane("main", [event(.answer, at: 0, usage: used), event(.tool, tool: "Read", at: 700), event(.answer, at: 710, usage: used)])
        let sub = lane("a1", parent: "main", [event(.answer, at: 1300, usage: used)])
        let a = anatomy([main, sub])
        let c = a.consumption(timeZone: TimeZone(secondsFromGMT: 0)!)
        let periods = c.buckets.filter { $0.calls > 0 }
        XCTAssertEqual(periods.count, 3)
        XCTAssertEqual(a.chatPlace(in: periods[0]), ChatPlace(lane: "main", event: 0))
        // Not the tool at 700: the first model call in the period.
        XCTAssertEqual(a.chatPlace(in: periods[1]), ChatPlace(lane: "main", event: 2))
        XCTAssertEqual(a.chatPlace(in: periods[2]), ChatPlace(lane: "a1", event: 0))
        XCTAssertEqual(a.firstCall(of: "a1", in: periods[2]), ChatPlace(lane: "a1", event: 0))
        XCTAssertNil(a.firstCall(of: "a1", in: periods[0]))
    }

    func testTheFilterIsClearedOnlyWhenItHidesThePlace() {
        let events = [event(.prompt), event(.tool, tool: "Bash"), event(.tool, tool: "Edit")]
        let f = ChatFilter(kinds: [.bash])
        XCTAssertEqual(f.showing(1, in: events), f)
        XCTAssertEqual(f.showing(2, in: events), ChatFilter())
    }
}
