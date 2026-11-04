import Foundation
import XCTest
@testable import CCOPKit

final class ConsumptionTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func d(_ s: String) -> Date { parseDate(s)! }

    func call(_ at: String, tokens: UInt64, lane: String = "main", cost: UInt64 = 1000) -> Consumption.Call {
        Consumption.Call(lane: lane, at: d(at), usage: TokenUsage(cacheReadTokens: tokens, requests: 1), costMicros: cost)
    }

    func testCallsAddUpInPeriodsThatStartAtRoundTimes() {
        let c = Consumption(calls: [
            call("2026-11-03T20:13:00Z", tokens: 100),
            call("2026-11-03T20:14:59Z", tokens: 50, lane: "a1"),
            call("2026-11-03T20:20:00Z", tokens: 10),
        ], maxBuckets: 60, timeZone: utc)
        // Seven minutes fit 60 bars of 1 minute.
        XCTAssertEqual(c.step, 60)
        XCTAssertEqual(c.buckets.first?.start, d("2026-11-03T20:13:00Z"))
        XCTAssertEqual(c.buckets.count, 8)
        XCTAssertEqual(c.buckets.map(\.usage.total), [100, 50, 0, 0, 0, 0, 0, 10])
        XCTAssertEqual(c.buckets.map(\.calls), [1, 1, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(c.usage.total, 160)
        XCTAssertEqual(c.costMicros, 3000)
    }

    func testALongSessionGetsLongerPeriodsAndAtMostMaxBuckets() {
        let c = Consumption(calls: [
            call("2026-11-03T20:13:00Z", tokens: 1),
            call("2026-11-04T01:40:00Z", tokens: 1),
        ], maxBuckets: 60, timeZone: utc)
        // 5 h 27 min: 5 min bars would be 66 bars, so 10 min bars.
        XCTAssertEqual(c.step, 600)
        XCTAssertEqual(c.stepText, "10 min")
        XCTAssertLessThanOrEqual(c.buckets.count, 60)
        XCTAssertEqual(c.buckets.first?.start, d("2026-11-03T20:10:00Z"))
        XCTAssertEqual(c.buckets.last?.end, d("2026-11-04T01:50:00Z"))
    }

    func testPeriodsAreRoundOnTheLocalClock() {
        // UTC+5:30: 20:00 UTC is 01:30 local, so an hour starts at 20:30 UTC.
        let india = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!
        let c = Consumption(calls: [
            call("2026-11-03T20:40:00Z", tokens: 1),
            call("2026-11-04T04:00:00Z", tokens: 1),
            call("2026-11-05T04:00:00Z", tokens: 1),
        ], maxBuckets: 60, timeZone: india)
        XCTAssertEqual(c.step, 3600)
        XCTAssertEqual(c.buckets.first?.start, d("2026-11-03T20:30:00Z"))
    }

    func testTheBiggestPeriodAndItsShareOfTheSession() throws {
        let c = Consumption(calls: [
            call("2026-11-03T20:00:00Z", tokens: 100),
            call("2026-11-03T20:01:00Z", tokens: 300),
            call("2026-11-03T20:02:00Z", tokens: 300),
            call("2026-11-03T20:03:00Z", tokens: 300),
        ], maxBuckets: 60, timeZone: utc)
        // Equal periods: the first one.
        XCTAssertEqual(c.biggest, 1)
        XCTAssertEqual(c.share(300), 0.3, accuracy: 1e-9)
    }

    func testAPeriodListsItsLanesMostTokensFirst() throws {
        let c = Consumption(calls: [
            call("2026-11-03T20:00:01Z", tokens: 10, lane: "main"),
            call("2026-11-03T20:00:02Z", tokens: 50, lane: "a1", cost: 7),
            call("2026-11-03T20:00:03Z", tokens: 5, lane: "a1", cost: 8),
            call("2026-11-03T20:00:04Z", tokens: 10, lane: "a0"),
        ], maxBuckets: 60, timeZone: utc)
        let lanes = try XCTUnwrap(c.buckets.first?.lanes)
        // Equal tokens go by id, so the order does not change between draws.
        XCTAssertEqual(lanes.map(\.id), ["a1", "a0", "main"])
        XCTAssertEqual(lanes.first?.usage.total, 55)
        XCTAssertEqual(lanes.first?.costMicros, 15)
    }

    func testNoCallsAndOneCall() {
        let none = Consumption(calls: [], maxBuckets: 60, timeZone: utc)
        XCTAssertTrue(none.buckets.isEmpty)
        XCTAssertNil(none.biggest)
        XCTAssertEqual(none.share(5), 0)
        let one = Consumption(calls: [call("2026-11-03T20:00:30Z", tokens: 9)], maxBuckets: 60, timeZone: utc)
        XCTAssertEqual(one.buckets.count, 1)
        XCTAssertEqual(one.biggest, 0)
        // Calls with no tokens have no biggest period.
        XCTAssertNil(Consumption(calls: [call("2026-11-03T20:00:30Z", tokens: 0)], maxBuckets: 60, timeZone: utc).biggest)
    }

    func testTheStepInWords() {
        var c = Consumption(calls: [], maxBuckets: 60, timeZone: utc)
        c.step = 900
        XCTAssertEqual(c.stepText, "15 min")
        c.step = 7200
        XCTAssertEqual(c.stepText, "2 h")
        c.step = 86400
        XCTAssertEqual(c.stepText, "1 day")
        c.step = 604_800
        XCTAssertEqual(c.stepText, "7 days")
    }

    func testTheAnatomyExampleAddsUpToItsLanes() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        let c = a.consumption(timeZone: utc)
        let all = a.lanes.reduce(TokenUsage()) { $0 + $1.usage }
        XCTAssertEqual(c.usage.total, all.total)
        XCTAssertEqual(c.costMicros, a.spend.costMicros)
        XCTAssertEqual(c.buckets.reduce(0) { $0 + $1.usage.total }, all.total)
    }
}
