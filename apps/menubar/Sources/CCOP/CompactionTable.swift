import CCOPKit
import SwiftUI

/// Every compaction of the session, in any lane: when, how much it removed and
/// what the next call read. The button goes to its place in the chat.
struct CompactionTable: View {
    @Environment(AppModel.self) private var model
    let anatomy: Anatomy
    @State private var sort = TableSort<Column>()
    @State private var showAll = false

    private static let firstRows = 12
    private static let buttonSize: CGFloat = 22
    private static let costHelp = "Its part of the model call right after it, as in Spend. The call that writes the summary is not in the transcript, so no cost in ccop includes it."

    private enum Column { case lane, trigger, start, time, before, after, next, cost }

    private static func ascending(_ column: Column, _ a: CompactionRow, _ b: CompactionRow) -> Bool {
        switch column {
        case .lane: a.laneName.localizedStandardCompare(b.laneName) == .orderedAscending
        case .trigger: (a.trigger ?? "") < (b.trigger ?? "")
        case .start: a.start < b.start
        case .time: a.duration < b.duration
        case .before: a.beforeTokens < b.beforeTokens
        case .after: (a.afterTokens ?? 0) < (b.afterTokens ?? 0)
        case .next: (a.nextCallTokens ?? 0) < (b.nextCallTokens ?? 0)
        case .cost: a.costMicros < b.costMicros
        }
    }

    var body: some View {
        let rows = sort.sorted(anatomy.compactionRows, ascending: Self.ascending)
        let shown = showAll ? rows : Array(rows.prefix(Self.firstRows))
        let lines = shown.map(Line.init)
        let widths = Widths(lines)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Compactions").font(.ui(13, .semibold))
                Text(anatomy.compactionSummary).font(.ui(11)).foregroundStyle(Theme.text3).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    SortTitle(title: "Agent", column: Column.lane, sort: $sort, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SortTitle(title: "Trigger", column: Column.trigger, sort: $sort, alignment: .leading)
                        .frame(width: widths.trigger, alignment: .leading)
                    SortTitle(title: "Start", column: Column.start, sort: $sort).frame(width: widths.start, alignment: .trailing)
                    SortTitle(title: "Time", column: Column.time, sort: $sort).frame(width: widths.time, alignment: .trailing)
                    SortTitle(title: "Before", column: Column.before, sort: $sort, help: "The context Claude Code gives for the moment before the compaction.")
                        .frame(width: widths.before, alignment: .trailing)
                    SortTitle(title: "After", column: Column.after, sort: $sort, help: "The context Claude Code gives for the moment after the compaction, without the system prompt and the tools.")
                        .frame(width: widths.after, alignment: .trailing)
                    SortTitle(title: "Next call", column: Column.next, sort: $sort, help: "The context the next model call of this agent really read.")
                        .frame(width: widths.next, alignment: .trailing)
                    SortTitle(title: "Cost", column: Column.cost, sort: $sort, help: Self.costHelp).frame(width: widths.cost, alignment: .trailing)
                    Color.clear.frame(width: Self.buttonSize, height: 1)
                }
                .padding(.vertical, 6)
                ForEach(lines, id: \.row.id) { line in
                    Rectangle().fill(Theme.line2).frame(height: 1)
                    row(line, widths)
                }
            }
            .font(.ui(12.5))
            if rows.count > Self.firstRows {
                Button(showAll ? "Show fewer" : "Show all \(rows.count)") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    /// One row's texts.
    private struct Line {
        let row: CompactionRow
        let trigger, start, time, before, after, next, cost: String

        init(_ row: CompactionRow) {
            self.row = row
            trigger = row.trigger ?? ""
            start = row.start.formatted(date: .omitted, time: .shortened)
            time = shortDuration(row.duration)
            before = Format.tokens(row.beforeTokens)
            after = row.afterTokens.map(Format.tokens) ?? "–"
            next = row.nextCallTokens.map(Format.tokens) ?? "–"
            cost = Format.dollars(row.costMicros)
        }
    }

    /// As wide as the widest title or value, so columns line up across rows.
    private struct Widths {
        let trigger, start, time, before, after, next, cost: CGFloat

        init(_ lines: [Line]) {
            let title = NSFont.systemFont(ofSize: 11, weight: .medium)
            let plain = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
            func width(_ name: String, _ value: (Line) -> String) -> CGFloat {
                max(textWidth(name, title) + SortTitle<Column>.arrowRoom, lines.map { textWidth(value($0), plain) }.max() ?? 0)
            }
            trigger = width("Trigger") { $0.trigger }
            start = width("Start") { $0.start }
            time = width("Time") { $0.time }
            before = width("Before") { $0.before }
            after = width("After") { $0.after }
            next = width("Next call") { $0.next }
            cost = width("Cost") { $0.cost }
        }
    }

    private func row(_ line: Line, _ widths: Widths) -> some View {
        let row = line.row
        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.bad).frame(width: 3, height: 14)
                Text(row.laneName).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.laneName)
            Text(line.trigger).foregroundStyle(Theme.text2).frame(width: widths.trigger, alignment: .leading)
            Text(line.start).frame(width: widths.start, alignment: .trailing)
            Text(line.time).frame(width: widths.time, alignment: .trailing)
            Text(line.before).frame(width: widths.before, alignment: .trailing)
            Text(line.after).frame(width: widths.after, alignment: .trailing)
            Text(line.next).frame(width: widths.next, alignment: .trailing)
            Text(line.cost).frame(width: widths.cost, alignment: .trailing).help(Self.costHelp)
            SmallIconButton(symbol: "bubble.left.and.text.bubble.right", help: "Show this compaction in Chat",
                            size: Self.buttonSize, fill: Theme.bg) {
                model.openInChat(row.place)
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .hoverRow()
        .rowMenu(view: nil,
                 goTo: { model.openInChat(row.place) },
                 fileName: RowExport.fileName(sessionID: anatomy.sessionId, name: "compaction \(row.laneName) \(row.place.event)"),
                 json: {
                     guard let lane = anatomy.lane(row.place.lane) else { throw CocoaError(.fileNoSuchFile) }
                     return try RowExport.encode(RowExport.call(sessionID: anatomy.sessionId, lane: lane, event: row.place.event))
                 })
    }
}
