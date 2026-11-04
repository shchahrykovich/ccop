import XCTest
@testable import CCOPKit

final class TableSortTests: XCTestCase {
    enum Column { case name, cost }
    struct Row: Equatable {
        let name: String
        let cost: Int
    }

    let rows = [Row(name: "b", cost: 2), Row(name: "a", cost: 3), Row(name: "c", cost: 2), Row(name: "d", cost: 1)]

    func order(_ sort: TableSort<Column>) -> [String] {
        sort.sorted(rows) { column, a, b in
            switch column {
            case .name: a.name < b.name
            case .cost: a.cost < b.cost
            }
        }.map(\.name)
    }

    func testAtFirstNoColumnIsSortedAndTheRowsKeepTheirOrder() {
        let sort = TableSort<Column>()
        XCTAssertNil(sort.direction(of: .cost))
        XCTAssertEqual(order(sort), ["b", "a", "c", "d"])
    }

    func testTheClicksGoDownThenUpThenBackToTheDefault() {
        var sort = TableSort<Column>()
        sort.click(.name)
        XCTAssertEqual(sort.direction(of: .name), .down)
        XCTAssertEqual(order(sort), ["d", "c", "b", "a"])
        sort.click(.name)
        XCTAssertEqual(sort.direction(of: .name), .up)
        XCTAssertEqual(order(sort), ["a", "b", "c", "d"])
        sort.click(.name)
        XCTAssertNil(sort.direction(of: .name))
        XCTAssertEqual(order(sort), ["b", "a", "c", "d"])
    }

    func testAClickOnAnotherColumnStartsItDownAndTheFirstColumnHasNoArrow() {
        var sort = TableSort<Column>()
        sort.click(.name)
        sort.click(.name)
        sort.click(.cost)
        XCTAssertEqual(sort.direction(of: .cost), .down)
        XCTAssertNil(sort.direction(of: .name))
    }

    func testRowsWithTheSameValueKeepTheirDefaultOrderInBothDirections() {
        var sort = TableSort<Column>()
        sort.click(.cost)
        XCTAssertEqual(order(sort), ["a", "b", "c", "d"], "down: b before c, both cost 2")
        sort.click(.cost)
        XCTAssertEqual(order(sort), ["d", "b", "c", "a"], "up: b still before c")
    }
}
