import XCTest
@testable import CCOPKit

final class WindowHistoryTests: XCTestCase {
    private let spend = WindowPlace(session: "a", tab: .spend)
    private let cause = WindowPlace(session: "a", tab: .cause, causeID: "tool:Bash")
    private let chat = WindowPlace(session: "a", tab: .chat, chatLane: "main", chatEvent: 12)

    private func history(_ places: WindowPlace...) -> WindowHistory {
        var h = WindowHistory()
        places.forEach { h.visit($0) }
        return h
    }

    func testAnEmptyHistoryHasNowhereToGo() {
        var h = WindowHistory()
        XCTAssertFalse(h.canGoBack)
        XCTAssertFalse(h.canGoForward)
        XCTAssertNil(h.goBack())
        XCTAssertNil(h.goForward())
        XCTAssertNil(h.current)
    }

    func testTheFirstPlaceHasNothingBeforeIt() {
        let h = history(spend)
        XCTAssertEqual(h.current, spend)
        XCTAssertFalse(h.canGoBack)
    }

    func testBackAndForwardWalkThePlacesInOrder() {
        var h = history(spend, cause, chat)
        XCTAssertEqual(h.goBack(), cause)
        XCTAssertEqual(h.goBack(), spend)
        XCTAssertNil(h.goBack())
        XCTAssertEqual(h.current, spend)
        XCTAssertEqual(h.goForward(), cause)
        XCTAssertEqual(h.goForward(), chat)
        XCTAssertNil(h.goForward())
        XCTAssertEqual(h.current, chat)
    }

    func testAPlaceFromTheHistoryAddsNoStep() {
        var h = history(spend, cause)
        let shown = h.goBack()!
        // The model records what the window shows after it restores a place.
        h.visit(shown)
        XCTAssertTrue(h.canGoForward)
        XCTAssertEqual(h.goForward(), cause)
    }

    func testTheSamePlaceTwiceIsOneStep() {
        var h = history(spend, cause, cause)
        XCTAssertEqual(h.goBack(), spend)
        XCTAssertFalse(h.canGoBack)
    }

    func testANewPlaceRemovesThePlacesAfterTheCurrentOne() {
        var h = history(spend, cause)
        _ = h.goBack()
        h.visit(chat)
        XCTAssertFalse(h.canGoForward)
        XCTAssertEqual(h.goBack(), spend)
    }

    func testTheOldestPlacesGoFirstAtTheLimit() {
        var h = WindowHistory(limit: 2)
        for tab in [DetailTab.overview, .spend, .cause, .chat] { h.visit(WindowPlace(session: "a", tab: tab)) }
        XCTAssertEqual(h.goBack()?.tab, .cause)
        XCTAssertEqual(h.goBack()?.tab, .spend)
        XCTAssertNil(h.goBack())
    }

    func testAPlaceKeepsOnlyWhatItsTabShows() {
        let onSpend = WindowPlace(session: "a", tab: .spend, chatLane: "agent-1", chatEvent: 3, causeID: "tool:Read")
        XCTAssertEqual(onSpend, WindowPlace(session: "a", tab: .spend))

        let onChat = WindowPlace(session: "a", tab: .chat, chatLane: "agent-1", chatEvent: 3, causeID: "tool:Read")
        XCTAssertEqual(onChat.chatLane, "agent-1")
        XCTAssertEqual(onChat.chatEvent, 3)
        XCTAssertNil(onChat.causeID)

        let onCause = WindowPlace(session: "a", tab: .cause, chatLane: "agent-1", chatEvent: 3, causeID: "tool:Read")
        XCTAssertEqual(onCause.causeID, "tool:Read")
        XCTAssertNil(onCause.chatLane)
        XCTAssertNil(onCause.chatEvent)
    }
}
