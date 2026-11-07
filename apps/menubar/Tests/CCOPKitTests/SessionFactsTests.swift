import Foundation
import XCTest
@testable import CCOPKit

final class SessionFactsTests: XCTestCase {
    func testCostByModelCountsOnlyModelCalls() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        // main: 102412 + 13305 + 17104; a1: 23004 + 2802. Prompts and tools are shares, not new cost.
        XCTAssertEqual(a.costByModel, ["claude-opus-5-5": 138_525, "claude-sonnet-5-5": 25806])
        XCTAssertEqual(a.subagentCostMicros, 25806)
    }

    func testALanesCostIsTheSumOfItsModelCalls() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        XCTAssertEqual(a.lanes.map(\.costMicros), [138_525, 25806])
    }

    func testPromptTimesAndContextSizeComeFromTheMainLane() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        XCTAssertEqual(a.promptTimes?.first, parseDate("2026-11-02T10:00:00Z"))
        XCTAssertEqual(a.promptTimes?.last, parseDate("2026-11-02T10:03:00Z"))
        // (20003 + 21704 + 22501) / 3 = 21402
        XCTAssertEqual(a.contextSize?.average, 21727)
        XCTAssertEqual(a.contextSize?.max, 22702)
    }
}
