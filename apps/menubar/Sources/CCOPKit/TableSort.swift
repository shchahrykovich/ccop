// A table's sort: which column, and which way. The first click on a column
// sorts it down (largest first), the second up, the third goes back to the
// table's own order.

import Foundation

public struct TableSort<Column: Equatable>: Equatable {
    public enum Direction: Equatable { case down, up }

    private var column: Column?
    private var direction = Direction.down

    public init() {}

    /// The column's arrow; nil when the table is not sorted by this column.
    public func direction(of column: Column) -> Direction? {
        self.column == column ? direction : nil
    }

    public mutating func click(_ column: Column) {
        if self.column != column {
            self.column = column
            direction = .down
        } else if direction == .down {
            direction = .up
        } else {
            self.column = nil
            direction = .down
        }
    }

    /// The rows in this order. `ascending` says whether the first row comes
    /// before the second in a sort from small to large. Rows with the same
    /// value keep their order, in both directions.
    public func sorted<Row>(_ rows: [Row], ascending: (Column, Row, Row) -> Bool) -> [Row] {
        guard let column else { return rows }
        return rows.enumerated().sorted { a, b in
            if ascending(column, a.element, b.element) { return direction == .up }
            if ascending(column, b.element, a.element) { return direction == .down }
            return a.offset < b.offset
        }.map(\.element)
    }
}
