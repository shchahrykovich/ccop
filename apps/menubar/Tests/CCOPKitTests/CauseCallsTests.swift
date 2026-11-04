import Foundation
import XCTest
@testable import CCOPKit

final class CauseCallsTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)
    private let used = TokenUsage(inputTokens: 1)

    private func ev(_ kind: EventKind, tool: String? = nil, at: TimeInterval, usage: TokenUsage? = nil, cost: UInt64? = nil) -> AnatomyEvent {
        let d = t.addingTimeInterval(at)
        return AnatomyEvent(kind: kind, start: d, end: d, usage: usage, tool: tool, isError: false, costMicros: cost)
    }

    private func cause(_ kind: CauseKind, _ name: String) -> Cause {
        Cause(kind: kind, name: name, count: 0, errors: 0, modelCalls: 0, costMicros: 0, tokens: 0, errorCostMicros: 0, avgContext: 0, addedTokens: 0)
    }

    private func lane(_ id: String, _ events: [AnatomyEvent]) -> AnatomyLane {
        AnatomyLane(id: id, name: id, usage: TokenUsage(), toolCalls: 0, errors: 0, events: events, context: [])
    }

    private var anatomy: Anatomy {
        let main = lane("main", [
            ev(.prompt, at: 0, cost: 5),                    // 0
            ev(.answer, at: 1, usage: used, cost: 5),       // 1: after the prompt
            ev(.tool, tool: "Bash", at: 2, cost: 7),        // 2
            ev(.answer, at: 3, cost: 0),                    // 3: no usage: does not end what came before
            ev(.answer, at: 4, usage: used, cost: 7),       // 4: after the tool
            ev(.error, at: 5),                              // 5: an API error is nothing new
            ev(.answer, at: 6, usage: used, cost: 9),       // 6: nothing new before it
            ev(.compact, at: 7, cost: 2),                   // 7
            ev(.answer, at: 8, usage: used, cost: 2),       // 8: after the compaction
            ev(.tool, at: 20, cost: 4),                     // 9: a tool with no name
        ])
        let sub = lane("a1", [
            ev(.prompt, at: 10, cost: 3),                   // 0: a subagent's task
            ev(.answer, at: 11, usage: used, cost: 3),      // 1
            ev(.tool, tool: "Bash", at: 12, cost: 1),       // 2
        ])
        return Anatomy(sessionId: "s1", lanes: [main, sub], turns: [], tools: [], contributors: [],
                       spend: Spend(costMicros: 0, tokens: 0, causes: [], lanes: [], tips: [], commands: [], errors: []))
    }

    func testAToolCauseListsThatToolInAllLanesInTimeOrder() {
        XCTAssertEqual(anatomy.calls(of: cause(.tool, "Bash")), [
            CallCost(lane: "main", event: 2, costMicros: 7),
            CallCost(lane: "a1", event: 2, costMicros: 1),
        ])
        XCTAssertEqual(anatomy.calls(of: cause(.tool, "Tool")).map(\.event), [9])
    }

    func testPromptsOfMainAreYourMessagesAndOfASubagentItsTask() {
        XCTAssertEqual(anatomy.calls(of: cause(.prompt, "Your prompts")), [CallCost(lane: "main", event: 0, costMicros: 5)])
        XCTAssertEqual(anatomy.calls(of: cause(.task, "Tasks from the lead")), [CallCost(lane: "a1", event: 0, costMicros: 3)])
    }

    func testCompactionAndStart() {
        XCTAssertEqual(anatomy.calls(of: cause(.compact, "Compaction")).map(\.event), [7])
        XCTAssertEqual(anatomy.calls(of: cause(.other, "Other")), [CallCost(lane: "main", event: 6, costMicros: 9)])
    }

    func testTitles() {
        XCTAssertEqual(cause(.tool, "Bash").title, "Bash results")
        XCTAssertEqual(cause(.other, "Other").title, "Start")
    }

    func testShownCausesHaveTheMostCostFirstAndNoEmptyOnes() {
        var a = cause(.tool, "A"); a.costMicros = 1
        var b = cause(.tool, "B"); b.costMicros = 9
        var c = cause(.tool, "C"); c.count = 1
        let d = cause(.tool, "D")
        let s = Spend(costMicros: 0, tokens: 0, causes: [a, b, c, d], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(s.shownCauses.map(\.name), ["B", "A", "C"])
    }

    /// The Rust code wrote these causes: the Swift list of calls must add up to them.
    func testTheCallsOfEachCauseAddUpToTheCauseFromRust() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        XCTAssertFalse(a.spend.causes.isEmpty)
        for c in a.spend.causes {
            let calls = a.calls(of: c)
            if c.kind != .other { XCTAssertEqual(UInt64(calls.count), c.count, c.name) }
            let sum = calls.reduce(0) { $0 + $1.costMicros }
            // Each part is rounded on its own: at most 1 micro-dollar per call apart.
            XCTAssertLessThanOrEqual(abs(Int64(sum) - Int64(c.costMicros)), Int64(calls.count) + 1, c.name)
        }
    }
}
