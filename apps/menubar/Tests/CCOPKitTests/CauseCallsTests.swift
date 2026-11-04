import Foundation
import XCTest
@testable import CCOPKit

final class CauseCallsTests: XCTestCase {
    private func cause(_ kind: CauseKind, _ name: String) -> Cause {
        Cause(kind: kind, name: name, count: 0, errors: 0, modelCalls: 0, costMicros: 0, tokens: 0, errorCostMicros: 0, avgContext: 0, addedTokens: 0, items: [])
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

    func testAToolNameFindsItsToolCauseOnly() {
        let s = Spend(costMicros: 0, tokens: 0, causes: [cause(.other, "Bash"), cause(.tool, "Bash"), cause(.tool, "Read")],
                      lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(s.cause(ofTool: "Bash")?.kind, .tool)
        XCTAssertEqual(s.cause(ofTool: "Read")?.name, "Read")
        XCTAssertNil(s.cause(ofTool: "Write"))
        let unnamed = Spend(costMicros: 0, tokens: 0, causes: [cause(.tool, "Tool")], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(unnamed.cause(ofTool: "")?.name, "Tool")
    }

    /// The Anatomy tab's tool cards open the Cause tab: Rust must name both the same.
    func testEveryToolOfTheExampleHasACauseWithItsCalls() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        XCTAssertFalse(a.tools.isEmpty)
        for t in a.tools {
            XCTAssertEqual(a.spend.cause(ofTool: t.tool)?.count, t.calls, t.tool)
        }
    }

    /// The Rust code wrote these causes and their calls (spend.rs tests the rules):
    /// the Cause tab's list must add up to the cause it stands under.
    func testTheCallsOfEachCauseAddUpToTheCauseFromRust() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        XCTAssertFalse(a.spend.causes.isEmpty)
        for c in a.spend.causes {
            if c.kind != .other { XCTAssertEqual(UInt64(c.items.count), c.count, c.name) }
            let sum = c.items.reduce(0) { $0 + $1.costMicros }
            // Each part is rounded on its own: at most 1 micro-dollar per call apart.
            XCTAssertLessThanOrEqual(abs(Int64(sum) - Int64(c.costMicros)), Int64(c.items.count) + 1, c.name)
            for item in c.items {
                let events = a.lane(item.lane)?.events ?? []
                XCTAssertTrue(events.indices.contains(item.event), "\(c.name): \(item)")
            }
        }
    }
}
