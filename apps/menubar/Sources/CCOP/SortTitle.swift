import CCOPKit
import SwiftUI

/// A column title that sorts its table when clicked, with an arrow for the
/// direction. The arrow is on the outer side of the title, so the title stays
/// in line with the column's values; a column's width must include `arrowRoom`.
struct SortTitle<Column: Equatable>: View {
    static var arrowRoom: CGFloat { 12 }

    let title: String
    let column: Column
    @Binding var sort: TableSort<Column>
    var alignment: HorizontalAlignment = .trailing
    var help: String?

    var body: some View {
        let direction = sort.direction(of: column)
        Button { sort.click(column) } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { arrow(direction) }
                Text(title).lineLimit(1)
                if alignment != .trailing { arrow(direction) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(direction == nil ? Theme.text3 : Theme.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "Sort by \(title)")
        .accessibilityValue(direction == .down ? "Sorted down" : direction == .up ? "Sorted up" : "")
    }

    @ViewBuilder
    private func arrow(_ direction: TableSort<Column>.Direction?) -> some View {
        if let direction {
            Image(systemName: direction == .down ? "arrow.down" : "arrow.up")
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
        }
    }
}
