import Foundation
import XCTest
@testable import CCOPKit

final class ChatFilterTests: XCTestCase {
    func ev(_ kind: EventKind, _ tool: String? = nil, cost: UInt64? = nil) -> AnatomyEvent {
        AnatomyEvent(kind: kind, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 0), tool: tool, isError: false, costMicros: cost)
    }

    // 0 prompt, 1 answer, 2 Bash, 3 Edit, 4 answer, 5 MultiEdit, 6 Write, 7 answer, 8 Agent, 9 Task, 10 Read, 11 compact
    lazy var events: [AnatomyEvent] = [
        ev(.prompt, cost: 50), ev(.answer, cost: 1_000), ev(.tool, "Bash", cost: 10), ev(.tool, "Edit", cost: 20),
        ev(.answer, cost: 900), ev(.tool, "MultiEdit", cost: 30), ev(.tool, "Write", cost: 40), ev(.answer, cost: 100),
        ev(.tool, "Agent", cost: 60), ev(.tool, "Task", cost: 70), ev(.tool, "Read", cost: 80), ev(.compact),
    ]

    func testNoFilterShowsEverything() {
        let f = ChatFilter()
        XCTAssertFalse(f.isOn)
        XCTAssertEqual(f.indices(events), Array(0..<12))
    }

    func testKindsAreJoinedWithOr() {
        XCTAssertEqual(ChatFilter(kinds: [.bash]).indices(events), [2])
        XCTAssertEqual(ChatFilter(kinds: [.edit]).indices(events), [3, 5])
        XCTAssertEqual(ChatFilter(kinds: [.write]).indices(events), [6])
        XCTAssertEqual(ChatFilter(kinds: [.user]).indices(events), [0])
        XCTAssertEqual(ChatFilter(kinds: [.agent]).indices(events), [8, 9])
        XCTAssertEqual(ChatFilter(kinds: [.bash, .user, .agent]).indices(events), [0, 2, 8, 9])
    }

    func testTopCostsAloneTakesTheMostExpensiveTenthOfAllMessages() {
        // 11 events have a cost: the top 10% is 2 of them (rounded up).
        XCTAssertEqual(ChatFilter(topCosts: true).indices(events), [1, 4])
    }

    func testTopCostsWithKindsTakesTheMostExpensiveOfThoseKinds() {
        // Edit, Write and Agent calls: 3, 5, 6, 8, 9; the top 10% of 5 is 1: Task at 70.
        XCTAssertEqual(ChatFilter(kinds: [.edit, .write, .agent], topCosts: true).indices(events), [9])
    }

    func testEqualCostsAtTheLineAreAllShown() {
        let same = [ev(.tool, "Bash", cost: 5), ev(.tool, "Bash", cost: 5), ev(.tool, "Bash", cost: 1)]
        XCTAssertEqual(ChatFilter(kinds: [.bash], topCosts: true).indices(same), [0, 1])
    }

    func testTopCostsSkipsMessagesWithoutACost() {
        let free = [ev(.tool, "Bash"), ev(.tool, "Bash", cost: 0), ev(.compact)]
        XCTAssertEqual(ChatFilter(topCosts: true).indices(free), [])
    }
}
