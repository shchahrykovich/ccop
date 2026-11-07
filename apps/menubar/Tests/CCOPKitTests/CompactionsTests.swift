import Foundation
import XCTest
@testable import CCOPKit

final class CompactionsTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    private func compact(at: TimeInterval, seconds: TimeInterval = 60, before: UInt64, after: UInt64?, trigger: String? = "auto", cost: UInt64? = nil) -> AnatomyEvent {
        AnatomyEvent(kind: .compact, start: t.addingTimeInterval(at), end: t.addingTimeInterval(at + seconds),
                     usage: TokenUsage(inputTokens: before), isError: false, contextTokens: nil, costMicros: cost, trigger: trigger, afterTokens: after)
    }

    private func answer(at: TimeInterval, context: UInt64) -> AnatomyEvent {
        let d = t.addingTimeInterval(at)
        return AnatomyEvent(kind: .answer, start: d, end: d, usage: TokenUsage(outputTokens: 1), isError: false, contextTokens: context)
    }

    private func lane(_ id: String, _ events: [AnatomyEvent]) -> AnatomyLane {
        AnatomyLane(id: id, name: id == "main" ? "Main session" : "Helper \(id)", usage: TokenUsage(), toolCalls: 0, errors: 0, events: events, context: [])
    }

    private func anatomy(_ lanes: [AnatomyLane]) -> Anatomy {
        Anatomy(sessionId: "s1", lanes: lanes, turns: [], tools: [], contributors: [],
                spend: Spend(costMicros: 0, tokens: 0, causes: [], lanes: [], tips: [], commands: [], errors: []))
    }

    func testRowsCoverEveryLaneInTimeOrder() {
        let a = anatomy([
            lane("main", [answer(at: 0, context: 400), compact(at: 500, before: 477, after: 30), answer(at: 600, context: 72)]),
            lane("a1", [compact(at: 100, before: 470, after: 39), answer(at: 200, context: 87)]),
        ])
        XCTAssertEqual(a.compactionRows.map(\.place), [ChatPlace(lane: "a1", event: 0), ChatPlace(lane: "main", event: 1)])
        XCTAssertEqual(a.compactionRows.map(\.laneName), ["Helper a1", "Main session"])
        XCTAssertEqual(a.compactions, 2)
    }

    func testARowHasTheNumbersOfItsEventAndOfTheNextCall() throws {
        let a = anatomy([lane("main", [compact(at: 0, seconds: 62, before: 477, after: 30, trigger: "manual", cost: 166),
                                       answer(at: 70, context: 72), answer(at: 80, context: 99)])])
        let row = try XCTUnwrap(a.compactionRows.first)
        XCTAssertEqual(row.trigger, "manual")
        XCTAssertEqual(row.duration, 62)
        XCTAssertEqual(row.beforeTokens, 477)
        XCTAssertEqual(row.afterTokens, 30)
        XCTAssertEqual(row.nextCallTokens, 72, "the first call after the compaction, not a later one")
        XCTAssertEqual(row.costMicros, 166)
    }

    func testALaneThatEndsAfterACompactionHasNoNextCall() throws {
        let a = anatomy([lane("main", [compact(at: 0, before: 477, after: nil, trigger: nil)])])
        let row = try XCTUnwrap(a.compactionRows.first)
        XCTAssertNil(row.nextCallTokens)
        XCTAssertNil(row.afterTokens)
        XCTAssertNil(row.trigger)
        XCTAssertEqual(row.costMicros, 0)
    }

    func testEachLaneCountsItsOwnCompactions() {
        let a = anatomy([lane("main", []),
                         lane("a1", [compact(at: 0, before: 1, after: 1), compact(at: 9, before: 1, after: 1)]),
                         lane("a2", [answer(at: 0, context: 1)])])
        XCTAssertEqual(a.lanes.map(\.compactions), [0, 2, 0])
    }

    func testTheSummaryNamesTheLanesOnlyWhenBothKindsHaveSome() {
        let one = compact(at: 0, before: 1, after: 1)
        XCTAssertEqual(anatomy([lane("main", [one]), lane("a1", [one, one])]).compactionSummary, "3 · 1 main · 2 in subagents")
        XCTAssertEqual(anatomy([lane("main", [one])]).compactionSummary, "1")
        XCTAssertEqual(anatomy([lane("main", []), lane("a1", [one, one])]).compactionSummary, "2")
    }
}
