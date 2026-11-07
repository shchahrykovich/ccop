import Foundation
import XCTest
@testable import CCOPKit

/// api/anatomy.example.json is written by the Rust test
/// libs/core/tests/api_example.rs from the real code.
final class AnatomyContractTests: XCTestCase {
    static var example: URL {
        SessionContractTests.example.deletingLastPathComponent().appendingPathComponent("anatomy.example.json")
    }

    /// At every call of every lane, the items add up to each part and to
    /// the size, as `context.rs` makes them.
    func testTheContextItemsOfEachCallAddUpToItsParts() throws {
        let a = try Anatomy.decode(Data(contentsOf: Self.example))
        XCTAssertFalse(a.lanes[0].contextItems.isEmpty)
        for lane in a.lanes {
            for (call, point) in lane.context.enumerated() {
                let rows = ContextContents.rows(lane, call: call, each: true, dir: nil)
                XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, point.total, "\(lane.id) call \(call)")
                for part in point.parts {
                    XCTAssertEqual(rows.filter { $0.part == part.name }.reduce(0) { $0 + $1.tokens }, part.tokens, "\(lane.id) call \(call) \(part.name)")
                }
            }
        }
    }

    func testTheExampleDecodes() throws {
        let a = try Anatomy.decode(Data(contentsOf: Self.example))
        XCTAssertEqual(a.sessionId, "s1")
        XCTAssertEqual(a.lanes.map(\.id), ["main", "a1"])
        let main = a.lanes[0]
        XCTAssertEqual(main.events.map(\.kind), [.prompt, .answer, .tool, .tool, .answer, .compact, .prompt, .answer, .tool])
        XCTAssertEqual(main.events[2].label, "Read")
        XCTAssertEqual(main.events[3].agentId, "a1")
        XCTAssertTrue(main.events[8].isError)
        XCTAssertEqual(main.context.count, 3)
        XCTAssertEqual(main.context[1].parts.map(\.name), ["Start", "Claude output", "Tool: Read", "Tool: Agent"])
        XCTAssertEqual(main.context[1].parts.reduce(0) { $0 + $1.tokens }, main.context[1].total)
        XCTAssertEqual(a.lanes[1].parent, "main")
        XCTAssertEqual(a.turns.map(\.prompt), ["write the report", "push"])
        XCTAssertEqual(a.turns[0].subagents, ["a1"])
        XCTAssertEqual(a.tools.map(\.tool), ["Agent", "Bash", "Read", "WebSearch"])
        XCTAssertEqual(a.contributors.first?.lane, "main")
        XCTAssertEqual(a.compactions, 1)
        XCTAssertEqual(main.events[5].trigger, "auto")
        XCTAssertNotNil(main.events[5].afterTokens)
        XCTAssertEqual(a.spend.causes.first?.name, "Your prompts")
        XCTAssertEqual(a.spend.causes.first?.kind, .prompt)
        XCTAssertEqual(a.spend.causes.first?.modelCalls, 1.5)
        XCTAssertEqual(a.spend.lanes.map(\.lane), ["main", "a1"])
        XCTAssertEqual(a.spend.lanes.reduce(0) { $0 + $1.costMicros }, a.spend.costMicros)
        XCTAssertEqual(a.turns.reduce(0) { $0 + $1.totalCostMicros }, a.spend.costMicros)
        XCTAssertEqual(a.spend.share(a.spend.costMicros), 1)
        XCTAssertEqual(a.spend.commands.map(\.group), ["git push"])
        XCTAssertEqual(a.spend.errors.first?.message, "rejected")
        XCTAssertNil(a.spend.errors.first?.cause)
        XCTAssertEqual(main.events[8].group, "git push")
        XCTAssertEqual(main.events[8].error, "rejected")
        XCTAssertNil(main.events[8].refusal)
        XCTAssertNil(a.spend.errors.first?.refusal)
        XCTAssertEqual(main.events[8].command, "git push")
        XCTAssertEqual(a.spend.commands.first?.items, [CallCost(lane: "main", event: 8, costMicros: 0)])
        // An answer has its own cost; a prompt pays its part of the call after it.
        XCTAssertEqual(main.events[1].costMicros, 102_412)
        XCTAssertEqual(main.events[0].costMicros, main.events[1].costMicros)
        XCTAssertNil(main.events[8].costMicros)
    }

    func testTheNextModelCallAfterAnEvent() throws {
        let main = try Anatomy.decode(Data(contentsOf: Self.example)).lanes[0]
        // prompt, answer, tool, tool, answer, compact, prompt, answer, tool
        XCTAssertEqual(main.nextAnswer(after: 0), 1)
        XCTAssertEqual(main.nextAnswer(after: 2), 4)
        XCTAssertEqual(main.nextAnswer(after: 3), 4)
        XCTAssertEqual(main.nextAnswer(after: 5), 7)
        XCTAssertNil(main.nextAnswer(after: 8))
        XCTAssertNil(main.nextAnswer(after: 100))
        XCTAssertEqual(main.maxAnswerCost, 102_412)
        // A prompt or tool has its part of the next call's tokens; an answer has its usage instead.
        XCTAssertEqual(main.events[0].paidTokens, 20_123)
        XCTAssertNil(main.events[1].paidTokens)
        XCTAssertNotNil(main.events[2].paidTokens)
    }

    func testTheCallsThatReadAnEventsTokens() throws {
        let main = try Anatomy.decode(Data(contentsOf: Self.example)).lanes[0]
        // prompt, answer, tool, tool, answer, compact, prompt, answer, tool;
        // one context point per answer: events 1, 4, 7.
        XCTAssertEqual(main.context.map(\.event), [1, 4, 7])
        // The first prompt is read by the calls before the compaction.
        XCTAssertEqual(main.readingCalls(after: 0), 0 ..< 2)
        XCTAssertEqual(main.readingCalls(after: 3), 1 ..< 2)
        // After the compaction only the call after it reads the new prompt.
        XCTAssertEqual(main.readingCalls(after: 6), 2 ..< 3)
        // No call after the last tool result.
        XCTAssertNil(main.readingCalls(after: 8))
    }

    func testChatAndCallDecode() throws {
        let chat = try LaneChat.decode(Data(#"{"lane":"main","texts":[{"event":0,"text":"Write the report.","thinking":false,"input":null,"output":null,"output_truncated":false},{"event":2,"text":null,"thinking":false,"input":{"command":"ls notes","description":"List notes","timeout":5000},"output":"a.md","output_truncated":true}]}"#.utf8))
        XCTAssertEqual(chat.byEvent[0]?.text, "Write the report.")
        XCTAssertEqual(chat.byEvent[2]?.input?["command"]?.string, "ls notes")
        XCTAssertTrue(chat.byEvent[2]?.outputTruncated ?? false)
        // Short fields first, sorted; a long text field (`command`) last.
        XCTAssertEqual(chat.byEvent[2]?.input?.fields.map(\.name), ["description", "timeout", "command"])
        XCTAssertEqual(chat.byEvent[2]?.input?.fields.map(\.text), ["List notes", "5000", "ls notes"])

        let call = try ToolCall.decode(Data(#"{"tool_use_id":"t1","tool":"Bash","input":{"command":"ls"},"output":"a.md","output_bytes":4,"output_truncated":false,"is_error":true}"#.utf8))
        XCTAssertEqual(call.toolUseId, "t1")
        XCTAssertEqual(call.input["command"]?.text, "ls")
        XCTAssertEqual(call.outputBytes, 4)
        XCTAssertTrue(call.isError)
        XCTAssertEqual(JSONValue.array([.number(1.5), .bool(true), .null]).text, "[\n  1.5,\n  true,\n  null\n]")
        XCTAssertEqual(JSONValue.string("x").fields.map(\.name), ["input"])
    }

    func testWorktreeRefusalsDecodeAndHaveTheirOwnIds() throws {
        let json = #"[{"tool":"Bash","message":"This session is isolated","count":2,"cost_micros":5,"example":null,"cause":"c","refusal":"loop"},{"tool":"Bash","message":"This session is isolated","count":1,"cost_micros":2,"example":null,"cause":"c","refusal":"stdin"}]"#
        let groups = try Session.makeDecoder().decode([ErrorGroup].self, from: Data(json.utf8))
        XCTAssertEqual(groups.map(\.refusal), ["loop", "stdin"])
        XCTAssertNotEqual(groups[0].id, groups[1].id)
    }

    func testTwoTipsOfOneKindHaveTheirOwnIds() throws {
        // Bash and Read calls give two many_calls tips; with one id SwiftUI showed the first twice.
        let json = #"[{"kind":"many_calls","title":"Bash calls made the model run","detail":"d","cost_micros":5,"saving_micros":null},{"kind":"many_calls","title":"Read calls made the model run","detail":"d","cost_micros":3,"saving_micros":null}]"#
        let tips = try Session.makeDecoder().decode([Tip].self, from: Data(json.utf8))
        XCTAssertNotEqual(tips[0].id, tips[1].id)
    }

    func testTipsDecode() throws {
        let json = #"[{"kind":"many_calls","title":"t","detail":"d","cost_micros":5,"saving_micros":null},{"kind":"cache_rewrites","title":"t","detail":"d","cost_micros":2,"saving_micros":2},{"kind":"late_compaction","title":"t","detail":"d","cost_micros":3,"saving_micros":1}]"#
        let tips = try Session.makeDecoder().decode([Tip].self, from: Data(json.utf8))
        XCTAssertEqual(tips.map(\.kind), [.manyCalls, .cacheRewrites, .lateCompaction])
        XCTAssertNil(tips[0].savingMicros)
        XCTAssertEqual(tips[1].savingMicros, 2)
    }

    func testTurnEventsAndTreeOrder() throws {
        let a = try Anatomy.decode(Data(contentsOf: Self.example))
        XCTAssertEqual(a.mainEvents(in: a.turns[0]).map(\.kind), [.prompt, .answer, .tool, .tool, .answer, .compact])
        XCTAssertEqual(a.mainEvents(in: a.turns[1]).map(\.kind), [.prompt, .answer, .tool])
        XCTAssertEqual(a.mainEventIndices(in: a.turns[1]), [6, 7, 8])
        XCTAssertEqual(a.lanesInTreeOrder.map(\.id), ["main", "a1"])
        XCTAssertEqual(a.depth(of: a.lanes[1]), 1)
        XCTAssertEqual(a.depth(of: a.lanes[0]), 0)
    }

    /// A row is indented by its depth, so a wrong depth pushes the row out of the window.
    func testALaneThatIsItsOwnParentIsNotDeep() throws {
        var a = try Anatomy.decode(Data(contentsOf: Self.example))
        a.lanes[1].parent = a.lanes[1].id
        XCTAssertEqual(a.depth(of: a.lanes[1]), 1)
    }

    func testAChainOfSubagentsKeepsItsDepth() throws {
        var a = try Anatomy.decode(Data(contentsOf: Self.example))
        var child = a.lanes[1]
        child.id = "a2"
        child.parent = a.lanes[1].id
        a.lanes.append(child)
        XCTAssertEqual(a.depth(of: child), 2)
    }
}

final class TimeScaleTests: XCTestCase {
    func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    func testLongGapsShrinkToAFixedWidth() {
        // 100 s of work, an hour of nothing, 100 s of work.
        let scale = TimeScale(spans: [(t(0), t(60)), (t(50), t(100)), (t(3700), t(3800))], maxGap: 120, gapWidth: 20)
        XCTAssertEqual(scale.segments.count, 2)
        XCTAssertEqual(scale.shownSeconds, 220)
        XCTAssertEqual(scale.activeSeconds, 200)
        XCTAssertEqual(scale.position(t(0)), 0)
        XCTAssertEqual(scale.position(t(100)), 100.0 / 220, accuracy: 1e-9)
        XCTAssertEqual(scale.position(t(3700)), 120.0 / 220, accuracy: 1e-9)
        XCTAssertEqual(scale.position(t(3800)), 1, accuracy: 1e-9)
        // A time in the gap goes to the gap's middle.
        XCTAssertEqual(scale.position(t(2000)), 110.0 / 220, accuracy: 1e-9)
        XCTAssertEqual(scale.gaps, [TimeScale.Gap(position: 110.0 / 220, duration: 3600)])
        XCTAssertEqual(scale.date(at: 120.0 / 220), t(3700))
        XCTAssertEqual(scale.date(at: 0.25), t(55))
    }

    func testShortGapsStay() {
        let scale = TimeScale(spans: [(t(0), t(10)), (t(70), t(80))], maxGap: 120)
        XCTAssertEqual(scale.segments.count, 1)
        XCTAssertEqual(scale.position(t(40)), 0.5, accuracy: 1e-9)
        XCTAssertTrue(scale.gaps.isEmpty)
    }

    func testNoSpans() {
        let scale = TimeScale(spans: [])
        XCTAssertEqual(scale.position(t(5)), 0)
        XCTAssertNil(scale.date(at: 0.5))
    }
}

final class TimeWindowTests: XCTestCase {
    func assertWindow(_ w: TimeWindow, _ lo: Double, _ hi: Double, line: UInt = #line) {
        XCTAssertEqual(w.lo, lo, accuracy: 1e-9, line: line)
        XCTAssertEqual(w.hi, hi, accuracy: 1e-9, line: line)
    }

    func testTheWholeTimelineMapsOneToOne() {
        let w = TimeWindow()
        XCTAssertTrue(w.isWhole)
        XCTAssertEqual(w.zoom, 1)
        XCTAssertEqual(w.view(0.25), 0.25)
        XCTAssertEqual(w.position(atView: 0.75), 0.75)
    }

    func testZoomKeepsThePointUnderTheAnchor() {
        var w = TimeWindow()
        w.zoom(by: 4)
        assertWindow(w, 0.375, 0.625)
        XCTAssertEqual(w.zoom, 4, accuracy: 1e-9)
        XCTAssertFalse(w.isWhole)

        // At a quarter of the view: position 0.3 stays at a quarter.
        var v = TimeWindow(lo: 0.2, hi: 0.6)
        v.zoom(by: 2, at: 0.25)
        assertWindow(v, 0.25, 0.45)
        XCTAssertEqual(v.view(0.3), 0.25, accuracy: 1e-9)

        var left = TimeWindow()
        left.zoom(by: 2, at: 0)
        assertWindow(left, 0, 0.5)
    }

    func testZoomStopsAtTheWholeTimelineAndAtTheDeepestZoom() {
        var w = TimeWindow(lo: 0.4, hi: 0.6)
        w.zoom(by: 0.01)
        assertWindow(w, 0, 1)
        w.zoom(by: 1e9, at: 1)
        assertWindow(w, 1 - TimeWindow.minSpan, 1)
        // A factor that means nothing leaves it as it is.
        let before = w
        w.zoom(by: 0)
        w.zoom(by: .infinity)
        XCTAssertEqual(w, before)
    }

    func testPanStopsAtTheEnds() {
        var w = TimeWindow(lo: 0.5, hi: 0.75)
        w.pan(by: 0.5)
        assertWindow(w, 0.625, 0.875)
        w.pan(by: 10)
        assertWindow(w, 0.75, 1)
        w.pan(by: -10)
        assertWindow(w, 0, 0.25)
    }

    func testRevealMovesOnlyWhenThePositionIsNotShown() {
        var w = TimeWindow(lo: 0, hi: 0.25)
        w.reveal(0.1)
        assertWindow(w, 0, 0.25)
        w.reveal(0.5)
        assertWindow(w, 0.375, 0.625)
        w.reveal(0.95)
        assertWindow(w, 0.75, 1)
    }

    func testAWindowOutsideTheTimelineIsMovedIn() {
        assertWindow(TimeWindow(lo: -0.2, hi: 0.3), 0, 0.5)
        assertWindow(TimeWindow(lo: 0.9, hi: 1.4), 0.5, 1)
        assertWindow(TimeWindow(lo: 0.5, hi: 0.4), 0.5, 0.5 + TimeWindow.minSpan)
    }
}
