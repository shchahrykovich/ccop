import CCOPKit
import Charts
import SwiftUI

/// The top of the Context tab: the tokens of the whole session over time, as
/// bars by kind, with the biggest period marked. The left axis is tokens, the
/// right axis the same bars as a percent of the session's tokens.
struct TokenTimeline: View {
    @Environment(AppModel.self) private var model
    let anatomy: Anatomy
    /// The bar under the pointer and the bar chosen with a click. With neither
    /// the biggest period shows.
    @State private var pick = ChartPick()
    @State private var width: CGFloat = 1000

    private static let height: CGFloat = 220
    private static let gutter: CGFloat = 40
    private static let lines = 4
    private static let gap: CGFloat = 20
    private static let aside: CGFloat = 270

    private struct Mark: Identifiable {
        var bucket: Int
        var kind: String
        var from: Double
        var to: Double
        var color: Color
        var id: String { "\(bucket) \(kind)" }
    }

    var body: some View {
        let c = anatomy.consumption()
        if let biggest = c.biggest {
            let shown = min(pick.shown(or: biggest), c.buckets.count - 1)
            let wide = width >= 460 + Self.gap + Self.aside
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: Self.gap))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.gap))
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Tokens over time").font(.system(size: 13, weight: .semibold))
                    Text("Main session and subagents. Each bar is \(c.stepText). Left axis: tokens. Right axis: percent of the session's tokens.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                layout {
                    chart(c, biggest: biggest, shown: shown).frame(maxWidth: .infinity)
                    card(c, shown: shown, biggest: biggest)
                        .frame(width: wide ? Self.aside : nil)
                        .frame(maxWidth: wide ? nil : .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    // MARK: Chart

    private func marks(_ c: Consumption) -> [Mark] {
        var out: [Mark] = []
        for (i, b) in c.buckets.enumerated() {
            var from: UInt64 = 0
            for kind in UsageBar.kinds {
                let n = b.usage[keyPath: kind.2]
                guard n > 0 else { continue }
                out.append(Mark(bucket: i, kind: kind.0, from: Double(from), to: Double(from + n), color: kind.1))
                from += n
            }
        }
        return out
    }

    private func chart(_ c: Consumption, biggest: Int, shown: Int) -> some View {
        let largest = c.buckets[biggest].usage.total
        let step = ContextChart.gridStep(for: largest)
        let top = Double(step) * Double(Self.lines)
        let count = c.buckets.count
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                grid(c, step: step)
                Chart {
                    RectangleMark(xStart: .value("From", Double(shown)), xEnd: .value("To", Double(shown + 1)),
                                  yStart: .value("Bottom", 0.0), yEnd: .value("Top", top))
                        .foregroundStyle(Theme.text.opacity(pick.pinned == nil ? 0.08 : 0.16))
                    ForEach(marks(c)) { m in
                        RectangleMark(xStart: .value("From", Double(m.bucket) + 0.1), xEnd: .value("To", Double(m.bucket) + 0.9),
                                      yStart: .value("Bottom", m.from), yEnd: .value("Top", m.to))
                            .foregroundStyle(m.color)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: 0.0 ... Double(count))
                .chartYScale(domain: 0.0 ... top)
                .chartOverlay { proxy in
                    ZStack {
                        GeometryReader { geo in
                            if let plot = proxy.plotFrame.map({ geo[$0] }),
                               let x = proxy.position(forX: Double(biggest) + 0.5),
                               let y = proxy.position(forY: Double(largest)) {
                                Text("biggest · \(Format.smallPercent(c.share(largest)))")
                                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Theme.text2)
                                    .fixedSize()
                                    .position(x: min(max(plot.minX + x, plot.minX + 44), plot.maxX - 44), y: plot.minY + y - 9)
                            }
                        }
                        .allowsHitTesting(false)
                        ChartPicker(proxy: proxy, pick: $pick) { x in
                            proxy.value(atX: x, as: Double.self).map { min(max(Int($0), 0), count - 1) }
                        }
                    }
                }
                .padding(.horizontal, Self.gutter)
            }
            .frame(height: Self.height)
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Bar chart of tokens over time. The biggest period has \(Format.tokens(largest)) tokens, \(Format.smallPercent(c.share(largest))) of the session.")

            xLabels(c).padding(.horizontal, Self.gutter)

            HStack(spacing: 14) {
                ForEach(UsageBar.kinds, id: \.0) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(kind.1).frame(width: 9, height: 9)
                        Text(kind.0)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.gutter)
        }
    }

    private func grid(_ c: Consumption, step: UInt64) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(1 ... Self.lines, id: \.self) { k in
                let tokens = step * UInt64(k)
                let y = Self.height - Self.height * CGFloat(k) / CGFloat(Self.lines)
                Rectangle().fill(Theme.line2).frame(height: 1).frame(maxWidth: .infinity).offset(y: y)
                HStack {
                    Text(Format.tokens(tokens))
                    Spacer(minLength: 0)
                    Text(Format.smallPercent(c.share(tokens)))
                }
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity)
                .offset(y: y + 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func xLabels(_ c: Consumption) -> some View {
        let n = c.buckets.count
        let marks = Array(Set([0, n / 2, n - 1])).sorted()
        return HStack(spacing: 0) {
            ForEach(Array(marks.enumerated()), id: \.element) { i, m in
                if i > 0 { Spacer(minLength: 8) }
                Text(time(c.buckets[m].start, c)).lineLimit(1)
            }
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(Theme.text3)
    }

    /// A time; with the date when the session runs over more than one day.
    private func time(_ date: Date, _ c: Consumption) -> String {
        let oneDay = c.buckets.first.map { Calendar.current.isDate($0.start, inSameDayAs: c.buckets.last?.start ?? $0.start) } ?? true
        return oneDay ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    // MARK: Card

    private func card(_ c: Consumption, shown: Int, biggest: Int) -> some View {
        let b = c.buckets[shown]
        let shape = RoundedRectangle(cornerRadius: 10)
        let limit = Plan.limitParts(costMicros: b.costMicros, weeklyBudgetMicros: model.plan.weeklyBudgetMicros)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(time(b.start, c)) – \(b.end.formatted(date: .omitted, time: .shortened))")
                if shown == biggest { Text("· biggest").fontWeight(.semibold) }
            }
            .font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(Theme.text3)
            VStack(alignment: .leading, spacing: 2) {
                (Text("\(Format.tokens(b.usage.total)) ").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    + Text("tokens").font(.system(size: 13)).foregroundStyle(Theme.text2))
                    .monospacedDigit()
                Text("\(Format.smallPercent(c.share(b.usage.total))) of the session's tokens")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
            }
            VStack(alignment: .leading, spacing: 5) {
                row("Cost", Format.dollars(b.costMicros))
                if let limit {
                    row("Day limit", limit.day).help(Self.limitHelp)
                    row("Week limit", limit.week).help(Self.limitHelp)
                }
                row("Model calls", "\(b.calls)")
            }
            .padding(.top, 4)
            // Always the room of `Self.laneRows` rows and the "more" line, so
            // the card and the page below it keep their place from bar to bar.
            VStack(alignment: .leading, spacing: 5) {
                Text("Who used them").font(.system(size: 11)).foregroundStyle(Theme.text3)
                ForEach(0 ..< Self.laneRows, id: \.self) { i in
                    if i < b.lanes.count {
                        let share = b.lanes[i]
                        LaneRow(title: name(share.id), value: Format.tokens(share.usage.total),
                                help: "\(name(share.id)): \(Format.tokens(share.usage.total)) tokens, \(Format.dollars(share.costMicros)). Click to see its first model call of this period in Chat.") {
                            if let place = anatomy.firstCall(of: share.id, in: b) { model.openInChat(place) }
                        }
                    } else {
                        row(" ", " ").hidden()
                    }
                }
                Text(b.lanes.count > Self.laneRows ? "and \(b.lanes.count - Self.laneRows) more" : " ")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .padding(.top, 4)
            Button("Go to Chat") {
                if let place = anatomy.chatPlace(in: b) { model.openInChat(place) }
            }
            .controlSize(.small)
            .disabled(anatomy.chatPlace(in: b) == nil)
            .help("Show the first model call of this period in the Chat tab")
            .padding(.top, 2)
            Text(pick.pinned == nil ? "Move the pointer over the chart to see a period. Click a bar to keep it here."
                : "This bar stays here. Click another bar to change it, or this bar to let it go.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: shape)
        .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
    }

    /// The lanes the card names; the others are counted.
    private static let laneRows = 4

    private static let limitHelp = "This period's cost against your limits. The limits count cost, not tokens, and a cache read costs far less than an output token. So the percent of the tokens and the percent of a limit can be far apart. The day limit is 1/7 of the week limit."

    private func name(_ lane: String) -> String {
        lane == "main" ? "Main" : anatomy.lane(lane)?.name ?? lane
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).lineLimit(1).fixedSize()
        }
        .font(.system(size: 12)).monospacedDigit()
    }
}

/// A lane in the card: a click goes to it in Chat.
private struct LaneRow: View {
    let title: String
    let value: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(value).lineLimit(1).fixedSize()
            }
            .font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(hovering ? Theme.accent : Theme.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
