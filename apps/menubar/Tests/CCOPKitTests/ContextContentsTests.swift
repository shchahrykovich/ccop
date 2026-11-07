import Foundation
import XCTest
@testable import CCOPKit

final class ContextContentsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ kind: EventKind, _ text: String? = nil, tool: String? = nil) -> AnatomyEvent {
        var e = AnatomyEvent(kind: kind, start: t0, end: t0, isError: false)
        e.text = text
        e.tool = tool
        return e
    }

    /// Two reads of one file, two answers and Start, at call 2 of 3; the
    /// second answer and the second read end at call 2.
    private var lane: AnatomyLane {
        let events = [
            event(.prompt, "read it"),
            event(.answer, "Reading"),
            event(.tool, "/p/docs/big.md", tool: "Read"),
            event(.answer, "Again"),
            event(.tool, "/p/docs/big.md", tool: "Read"),
            event(.answer, "Done"),
        ]
        var lane = AnatomyLane(id: "main", name: "Main session", usage: TokenUsage(), toolCalls: 2, errors: 0, events: events, context: [])
        lane.contextItems = [
            ContextItem(event: nil, part: "Start", firstCall: 0, lastCall: 2, tokens: 20_000),
            ContextItem(event: 1, part: "Claude output", firstCall: 1, lastCall: 2, tokens: 100),
            ContextItem(event: 2, part: "Tool: Read", firstCall: 1, lastCall: 2, tokens: 3000),
            ContextItem(event: 3, part: "Claude output", firstCall: 2, lastCall: 2, tokens: 50),
            ContextItem(event: 4, part: "Tool: Read", firstCall: 2, lastCall: 2, tokens: 1000),
        ]
        return lane
    }

    func testOneFileReadTwiceIsOneRowAndTheAnswersAreOneRow() {
        let rows = ContextContents.rows(lane, call: 2, each: false, dir: "/p")
        XCTAssertEqual(rows.map(\.label), ["Start", "docs/big.md", "Claude output"])
        XCTAssertEqual(rows.map(\.tokens), [20_000, 4000, 150])
        XCTAssertEqual(rows[1].events, [2, 4])
        XCTAssertEqual(rows[2].events, [1, 3])
    }

    func testEachItemIsItsOwnRow() {
        let rows = ContextContents.rows(lane, call: 2, each: true, dir: nil)
        XCTAssertEqual(rows.map(\.label), ["Start", "/p/docs/big.md", "/p/docs/big.md", "Reading", "Again"])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, 24_150)
    }

    /// Claude Code cut the first read; the second read the rest with `offset`.
    /// Each addition names the lines, so the rows do not look like one read
    /// twice; grouped, they stay one row of the file.
    func testEachAdditionNamesTheLinesOfAPartialRead() {
        var l = lane
        l.events[2].lines = FileLines(start: 1, end: 289, total: 376)
        l.events[4].lines = FileLines(start: 290, end: 376, total: 376)
        let rows = ContextContents.rows(l, call: 2, each: true, dir: "/p")
        XCTAssertEqual(rows.filter { $0.part == "Tool: Read" }.map(\.label),
                       ["docs/big.md · lines 1–289 of 376", "docs/big.md · lines 290–376 of 376"])
        XCTAssertEqual(ContextContents.rows(l, call: 2, each: false, dir: "/p").map(\.label), ["Start", "docs/big.md", "Claude output"])
    }

    func testAnEarlierCallHoldsOnlyWhatCameBeforeIt() {
        XCTAssertEqual(ContextContents.rows(lane, call: 0, each: false, dir: nil).map(\.label), ["Start"])
        XCTAssertEqual(ContextContents.rows(lane, call: 1, each: false, dir: "/p").map(\.label), ["Start", "docs/big.md", "Claude output"])
        XCTAssertEqual(ContextContents.rows(lane, call: 5, each: false, dir: nil), [])
    }

    func testAReportIsNamedByItsSubagent() {
        var e = event(.report, "All checks pass.")
        e.agentId = "a1"
        var l = AnatomyLane(id: "main", name: "Main session", usage: TokenUsage(), toolCalls: 0, errors: 0, events: [e], context: [])
        l.contextItems = [ContextItem(event: 0, part: "Subagent reports", firstCall: 0, lastCall: 0, tokens: 900)]
        XCTAssertEqual(ContextContents.rows(l, call: 0, each: false, dir: nil, names: ["a1": "Draft chapter 2"]).map(\.label), ["Draft chapter 2"])
        XCTAssertEqual(ContextContents.rows(l, call: 0, each: true, dir: nil, names: ["a1": "Draft chapter 2"]).map(\.label), ["Draft chapter 2: All checks pass."])
        XCTAssertEqual(ContextContents.rows(l, call: 0, each: false, dir: nil).map(\.label), ["from a1"])
    }

    func testAReportLosesItsFrame() {
        let text = "Another Claude session sent a message:\n<agent-message from=\"a1\">\n[Subagent hand-back] Not from the user. The report follows:\n  **Done.**\n  \n  - one\n</agent-message>"
        XCTAssertEqual(ContextContents.reportBody(text), "**Done.**\n\n- one")
        XCTAssertEqual(ContextContents.reportBody("plain text"), "plain text")
    }

    func testPathsAreShownFromTheProjectFolder() {
        XCTAssertEqual(ContextContents.inFolder("/Users/me/shop/src/a.rs", "/Users/me/shop"), "src/a.rs")
        XCTAssertEqual(ContextContents.inFolder("/Users/me/shop/src/a.rs", "/Users/me/shop/"), "src/a.rs")
        XCTAssertEqual(ContextContents.inFolder("/Users/me/shopping/a.rs", "/Users/me/shop"), "/Users/me/shopping/a.rs")
        XCTAssertEqual(ContextContents.inFolder("…ers/me/shop/src/a.rs", "/Users/me/shop"), "src/a.rs")
        XCTAssertEqual(ContextContents.inFolder("…ers/me/other/a.rs", "/Users/me/shop"), "…ers/me/other/a.rs")
        XCTAssertEqual(ContextContents.inFolder("Read the plan", "/Users/me/shop"), "Read the plan")
        XCTAssertEqual(ContextContents.inFolder("/Users/me/shop/a.rs", ""), "/Users/me/shop/a.rs")
    }
}
