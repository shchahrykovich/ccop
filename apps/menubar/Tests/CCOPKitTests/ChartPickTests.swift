import XCTest
@testable import CCOPKit

final class ChartPickTests: XCTestCase {
    func testThePointerShowsAValueAndLeavingShowsTheFallback() {
        var p = ChartPick()
        XCTAssertEqual(p.shown(or: 9), 9)
        p.hover(3)
        XCTAssertEqual(p.shown(or: 9), 3)
        p.hover(nil)
        XCTAssertEqual(p.shown(or: 9), 9)
    }

    func testAClickKeepsTheValueWhenThePointerLeaves() {
        var p = ChartPick()
        p.hover(3)
        p.drag(to: 3)
        p.release()
        p.hover(nil)
        XCTAssertEqual(p.pinned, 3)
        XCTAssertEqual(p.shown(or: 9), 3)
    }

    func testTheKeptValueWinsOverThePointer() {
        var p = ChartPick()
        p.drag(to: 3)
        p.release()
        p.hover(5)
        XCTAssertEqual(p.shown(or: 9), 3)
    }

    func testAClickOnAnotherValueMovesIt() {
        var p = ChartPick()
        p.drag(to: 3)
        p.release()
        p.drag(to: 5)
        p.release()
        XCTAssertEqual(p.pinned, 5)
    }

    func testASecondClickOnTheKeptValueLetsItGo() {
        var p = ChartPick()
        p.drag(to: 3)
        p.release()
        p.drag(to: 3)
        XCTAssertEqual(p.shown(or: 9), 3, "stays until the button goes up")
        p.release()
        XCTAssertNil(p.pinned)
        XCTAssertEqual(p.shown(or: 9), 9)
    }

    func testADragKeepsWhereItEndsEvenBackOnTheKeptValue() {
        var p = ChartPick()
        p.drag(to: 3)
        p.release()
        p.drag(to: 3)
        p.drag(to: 4)
        p.drag(to: 3)
        p.release()
        XCTAssertEqual(p.pinned, 3)
    }
}
