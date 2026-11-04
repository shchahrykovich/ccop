import AppKit
import CCOPKit
import SwiftUI

/// The Spend tab: where the cost of a session went, and what to change.
/// The numbers come from libs/core/src/spend.rs. The look follows the design
/// board WindowSpend (CSS px = points).
struct SpendView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let anatomy: Anatomy

    var body: some View {
        let s = anatomy.spend
        PageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(s)
                TipList(spend: s)
                FlexPair(bases: (300, 380), grows: (1, 1.4), gap: 28) {
                    CauseTable(spend: s)
                    PromptCosts(anatomy: anatomy)
                }
                if !s.commands.isEmpty { CommandTable(session: session, anatomy: anatomy) }
            }
            .foregroundStyle(SpendStyle.text)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The cost, then what it means; side by side on their first baselines, wrapping when narrow.
    private func header(_ s: Spend) -> some View {
        BaselineWrap(columnGap: 18, rowGap: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dollars(s.costMicros))
                    .font(.system(size: 28, weight: .semibold)).tracking(-0.56).monospacedDigit()
                    .help(facts(s))
                if let share = Plan.limitShare(costMicros: s.costMicros, weeklyBudgetMicros: model.plan.weeklyBudgetMicros) {
                    Text(share)
                        .font(.system(size: 11)).foregroundStyle(SpendStyle.text3).monospacedDigit()
                        .fixedSize()
                        .help(Plan.limitShareHelp)
                }
            }
            Paragraph(
                text: "Every model call reads the whole context again. So a session costs about: model calls × context size. Each call's cost goes to what made the model run.",
                size: 13, color: SpendStyle.text2)
                .frame(maxWidth: 560, alignment: .leading)
                .help("Cost is at API prices, so a cheap cache read weighs less than an output token. What made the model run: a tool result, your message, or the task a subagent got.")
        }
    }

    /// The smaller numbers about the cost, shown when the pointer is on it.
    private func facts(_ s: Spend) -> String {
        ["API-equivalent cost", "\(Format.tokens(s.tokens)) tokens", "\(s.lanes.reduce(0) { $0 + $1.modelCalls }) model calls"]
            .joined(separator: " · ")
    }
}

// MARK: - Style

/// The colors of the design board (StyleSheet), with dark values.
private enum SpendStyle {
    static let text = Theme.dynamic(0x1D1D1F, 0xF5F5F7)
    static let text2 = Theme.dynamic(0x5F5F64, 0xB9B9BF)
    static let text3 = Theme.dynamic(0x6E6E73, 0xA1A1A8)
    static let accent = Theme.dynamic(0x2563EB, 0x5B8CFF)
    static let accentSoft = alpha(0x2563EB, 0.07, 0x5B8CFF, 0.12)
    static let accentLine = alpha(0x2563EB, 0.20, 0x5B8CFF, 0.30)
    static let soft = Theme.card
    static let line = alpha(0x000000, 0.10, 0xFFFFFF, 0.12)
    static let line2 = alpha(0x000000, 0.06, 0xFFFFFF, 0.08)
    static let track = alpha(0x000000, 0.07, 0xFFFFFF, 0.10)
    static let code = alpha(0x000000, 0.05, 0xFFFFFF, 0.09)
    static let neutralTile = alpha(0x000000, 0.06, 0xFFFFFF, 0.08)
    static let neutralBar = Theme.dynamic(0x8A8A90, 0x8E8E93)

    static let row: CGFloat = 12.5

    static func alpha(_ light: UInt32, _ lightAlpha: CGFloat, _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(rgb: dark).withAlphaComponent(darkAlpha)
                : NSColor(rgb: light).withAlphaComponent(lightAlpha)
        })
    }

    /// The space CSS `line-height: 1.45` adds to a line of the system font.
    static func extraLeading(_ size: CGFloat, lineHeight: CGFloat = 1.45) -> CGFloat {
        let f = NSFont.systemFont(ofSize: size)
        return max(0, size * lineHeight - (f.ascender - f.descender + f.leading))
    }

    /// The width of one line of text, as a table column measures it.
    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Text with CSS `line-height: 1.45`: the extra space between lines and half of it above and below.
/// Words between backticks show as inline code.
private struct Paragraph: View {
    let text: String
    let size: CGFloat
    var color: Color = SpendStyle.text2

    var body: some View {
        let gap = SpendStyle.extraLeading(size)
        Text(Self.attributed(text, size: size))
            .font(.system(size: size))
            .foregroundStyle(color)
            .lineSpacing(gap)
            .padding(.vertical, gap / 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `code` spans: SF Mono 11.5 on a light grey, with a little space each side.
    static func attributed(_ text: String, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        for (i, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            if i % 2 == 1, !part.isEmpty {
                var pad = AttributedString("\u{2004}")
                pad.backgroundColor = SpendStyle.code
                var code = AttributedString(String(part))
                code.font = .system(size: 11.5, design: .monospaced)
                code.backgroundColor = SpendStyle.code
                out += pad + code + pad
            } else {
                out += AttributedString(i % 2 == 1 ? "``" : String(part))
            }
        }
        return out
    }
}

/// A section title with a short grey note beside it.
private struct SectionHeader: View {
    let title: String
    var note: String?
    var noteSize: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let note {
                Text(note).font(.system(size: noteSize)).foregroundStyle(SpendStyle.text3).monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The small grey column titles of a table.
private struct ColumnTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(SpendStyle.text3).lineLimit(1)
    }
}

/// The thin line on top of each table row.
private struct RowLine: View {
    var body: some View {
        Rectangle().fill(SpendStyle.line2).frame(height: 1)
    }
}

/// A blue text button: "Show 17 more".
private struct MoreButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(SpendStyle.accent)
                .padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

/// A part of the whole, as a short bar.
struct ShareBar: View {
    let share: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(SpendStyle.track)
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, share))))
            }
        }
        .frame(width: 90, height: 6)
    }
}

// MARK: - Layouts

/// CSS `display: flex; flex-wrap: wrap; align-items: baseline; gap: row column` for two views.
private struct BaselineWrap: Layout {
    var columnGap: CGFloat
    var rowGap: CGFloat

    private func plan(_ width: CGFloat, _ subviews: Subviews) -> (oneLine: Bool, sizes: [CGSize]) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let total = ideal.reduce(0) { $0 + $1.width } + columnGap * CGFloat(max(0, subviews.count - 1))
        let oneLine = total <= width
        // Measure again at the chosen width: a view with a max width (the text) wraps there.
        let sizes = subviews.indices.map { i in
            subviews[i].sizeThatFits(ProposedViewSize(width: min(ideal[i].width, width), height: nil))
        }
        return (oneLine, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let p = plan(width, subviews)
        if p.oneLine {
            let (above, below) = baselineBox(subviews, p.sizes)
            return CGSize(width: proposal.width ?? p.sizes.reduce(0) { $0 + $1.width }, height: above + below)
        }
        let h = p.sizes.reduce(0) { $0 + $1.height } + rowGap * CGFloat(max(0, p.sizes.count - 1))
        return CGSize(width: proposal.width ?? (p.sizes.map(\.width).max() ?? 0), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(bounds.width, subviews)
        if p.oneLine {
            let (above, _) = baselineBox(subviews, p.sizes)
            var x = bounds.minX
            for (i, s) in subviews.enumerated() {
                let base = s.dimensions(in: ProposedViewSize(p.sizes[i]))[VerticalAlignment.firstTextBaseline]
                s.place(at: CGPoint(x: x, y: bounds.minY + above - base), proposal: ProposedViewSize(p.sizes[i]))
                x += p.sizes[i].width + columnGap
            }
        } else {
            var y = bounds.minY
            for (i, s) in subviews.enumerated() {
                s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(p.sizes[i]))
                y += p.sizes[i].height + rowGap
            }
        }
    }

    /// The tallest part above and below the shared first baseline.
    private func baselineBox(_ subviews: Subviews, _ sizes: [CGSize]) -> (CGFloat, CGFloat) {
        var above: CGFloat = 0
        var below: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let base = s.dimensions(in: ProposedViewSize(sizes[i]))[VerticalAlignment.firstTextBaseline]
            above = max(above, base)
            below = max(below, sizes[i].height - base)
        }
        return (above, below)
    }
}

/// CSS `display: flex; flex-wrap: wrap; gap` for two views with `flex: grow 1 basis`:
/// side by side when both bases fit, the extra width split by grow; else one under the other.
private struct FlexPair: Layout {
    var bases: (CGFloat, CGFloat)
    var grows: (CGFloat, CGFloat)
    var gap: CGFloat

    private func widths(_ width: CGFloat) -> (CGFloat, CGFloat)? {
        let extra = width - bases.0 - bases.1 - gap
        guard extra >= 0 else { return nil }
        let g = grows.0 + grows.1
        return (bases.0 + extra * grows.0 / g, bases.1 + extra * grows.1 / g)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (bases.0 + bases.1 + gap)
        guard subviews.count == 2 else { return CGSize(width: width, height: 0) }
        if let w = widths(width) {
            let h = max(subviews[0].sizeThatFits(ProposedViewSize(width: w.0, height: nil)).height,
                        subviews[1].sizeThatFits(ProposedViewSize(width: w.1, height: nil)).height)
            return CGSize(width: width, height: h)
        }
        let h = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height } + gap
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if let w = widths(bounds.width) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: w.0, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + w.0 + gap, y: bounds.minY), proposal: ProposedViewSize(width: w.1, height: nil))
        } else {
            let p = ProposedViewSize(width: bounds.width, height: nil)
            subviews[0].place(at: bounds.origin, proposal: p)
            let h0 = subviews[0].sizeThatFits(p).height
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + h0 + gap), proposal: p)
        }
    }
}

/// One table row of cells with set widths. `flexible` takes the width left over.
private struct TableRow: Layout {
    var widths: [CGFloat]
    var flexible: Int?

    private func resolved(_ width: CGFloat) -> [CGFloat] {
        guard let flexible else { return widths }
        var w = widths
        w[flexible] = max(0, width - widths.enumerated().reduce(0) { $0 + ($1.offset == flexible ? 0 : $1.element) })
        return w
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? widths.reduce(0, +)
        let w = resolved(width)
        let h = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (s, w) in zip(subviews, resolved(bounds.width)) {
            s.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w
        }
    }
}

/// A table cell: CSS `td` with 1 pt of padding left and right.
private extension View {
    func cell(_ alignment: Alignment = .leading, padding: CGFloat = 1) -> some View {
        self.lineLimit(1)
            .padding(.horizontal, padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

// MARK: - Tips

struct TipList: View {
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What to change", note: summary, noteSize: 12)
            if spend.tips.isEmpty {
                Text("ccop found nothing large to change in this session.")
                    .font(.system(size: 12)).foregroundStyle(SpendStyle.text2)
            } else {
                // One tip per row, the full width, in the order of the list.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(spend.tips) { TipCard(tip: $0, spend: spend) }
                }
            }
        }
    }

    /// "3 tips · save up to $3.45 (43%)". Savings can overlap, so their sum is capped at the session's cost.
    private var summary: String? {
        guard !spend.tips.isEmpty else { return nil }
        let count = spend.tips.count == 1 ? "1 tip" : "\(spend.tips.count) tips"
        let saving = min(spend.costMicros, spend.tips.reduce(0) { $0 + ($1.savingMicros ?? 0) })
        guard saving > 0 else { return count }
        return "\(count) · save up to \(Format.dollars(saving)) (\(Format.percent(spend.share(saving))))"
    }
}

/// One tip as a row: the saving (or the cost) on the left, then the title
/// and what to do.
private struct TipCard: View {
    let tip: Tip
    let spend: Spend

    var body: some View {
        let saving = tip.savingMicros
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let saving {
                    Text("−\(Format.dollars(saving))")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(SpendStyle.accent)
                    Text("\(Format.percent(spend.share(saving))) of the session")
                        .font(.system(size: 11)).foregroundStyle(SpendStyle.text3)
                } else {
                    Text(Format.dollars(tip.costMicros))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tip.kind == .errors ? Theme.bad : SpendStyle.text)
                    Text("\(Format.percent(spend.share(tip.costMicros))) \(tip.kind == .errors ? "spent on errors" : "of the session")")
                        .font(.system(size: 11)).foregroundStyle(SpendStyle.text3)
                }
            }
            .monospacedDigit()
            .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Paragraph(text: tip.detail, size: 12)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(saving != nil ? SpendStyle.accentSoft : SpendStyle.soft, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(saving != nil ? SpendStyle.accentLine : SpendStyle.line))
    }
}

// MARK: - Causes

/// What made the model run, the most cost first, as bars relative to the biggest cause.
struct CauseTable: View {
    @Environment(AppModel.self) private var model
    let spend: Spend

    var body: some View {
        let causes = spend.shownCauses
        let top = max(1, causes.first?.costMicros ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "By cause")
                .help("After a tool result the model runs again and reads the whole context. A call after several results counts a part for each. Point at a row for its numbers; click it to see each call.")
            ForEach(causes) { c in
                let look = look(c)
                // grid-template-columns: 24px 112px 1fr 52px; gap: 10px
                HStack(spacing: 10) {
                    Image(systemName: look.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(look.icon)
                        .frame(width: 24, height: 24)
                        .background(look.tile, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    Text(c.title).lineLimit(1).frame(width: 112, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(SpendStyle.track)
                            RoundedRectangle(cornerRadius: 4).fill(look.bar)
                                .frame(width: g.size.width * min(1, Double(c.costMicros) / Double(top)))
                        }
                    }
                    .frame(height: 8)
                    Text(Format.dollars(c.costMicros)).fontWeight(.medium).lineLimit(1)
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: SpendStyle.row))
                .monospacedDigit()
                .help(help(c))
                .clickableRow {
                    model.causeID = c.id
                    model.windowTab = .cause
                }
                .accessibilityHint("Shows each call of this cause")
            }
        }
    }

    /// The symbol, its color, the tile behind it and the bar, as on the board.
    private func look(_ c: Cause) -> (symbol: String, icon: Color, tile: Color, bar: Color) {
        switch c.kind {
        case .tool:
            let t = Theme.tool(c.name)
            switch t.symbol {
            case "doc.text": return (t.symbol, Theme.dynamic(0xA16207, 0xEAB308), t.color.opacity(0.14), t.color)
            case "terminal": return (t.symbol, t.color, t.color.opacity(0.12), t.color)
            default: return (t.symbol, t.color, t.color.opacity(0.11), t.color)
            }
        case .prompt: return ("bubble.left", Theme.prompt, Theme.prompt.opacity(0.12), Theme.prompt)
        case .task: return ("point.3.connected.trianglepath.dotted", Theme.agent, Theme.agent.opacity(0.11), Theme.agent)
        case .compact: return ("arrow.down.right.and.arrow.up.left", Theme.warn, Theme.warn.opacity(0.12), Theme.warn)
        case .other: return ("flag", SpendStyle.text2, SpendStyle.neutralTile, SpendStyle.neutralBar)
        }
    }

    private func help(_ c: Cause) -> String {
        let what = switch c.kind {
        case .prompt: "Model calls right after one of your messages."
        case .task: "The first call of a subagent, after the task its lead gave it."
        case .compact: "Model calls right after a compaction."
        case .other: "Model calls with nothing new before them in their lane: the start, with the system prompt."
        case .tool:
            c.errorCostMicros > 0
                ? "Model calls after \(c.name) results. \(Format.dollars(c.errorCostMicros)) of it came after failed calls."
                : "Model calls after \(c.name) results."
        }
        var lines = [what, "\(Format.dollars(c.costMicros)), \(Format.percent(spend.share(c.costMicros))) of the session."]
        if c.count > 0 { lines.append("Count: \(c.count)" + (c.errors > 0 ? ", \(c.errors) failed" : "")) }
        lines.append("Model calls: \(Int(c.modelCalls.rounded()))")
        if c.avgContext > 0 { lines.append("Avg context: \(Format.tokens(c.avgContext))") }
        if c.addedTokens > 0 { lines.append("Context added: \(Format.tokens(c.addedTokens)) (estimated)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Your messages

/// Each of your prompts and what its turn cost, with the subagents it started.
struct PromptCosts: View {
    let anatomy: Anatomy
    @State private var showAll = false
    private let shownAtFirst = 8
    /// Columns #, Time, Message, Calls, Cost (the message takes the rest).
    private let columns = TableRow(widths: [22, 46, 0, 44, 60], flexible: 2)

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        let turns = anatomy.turns
        let shown = showAll ? turns : Array(turns.prefix(shownAtFirst))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Your messages", note: "the main session's calls until your next message")
                .help("Cost: the main session's calls until your next message, and the subagents started in that time. Point at a row for the split.")
            VStack(spacing: 0) {
                columns {
                    ColumnTitle("#").cell(padding: 0)
                    ColumnTitle("Time").cell()
                    ColumnTitle("Message").cell()
                    ColumnTitle("Calls").cell(.trailing)
                    ColumnTitle("Cost").cell(.trailing)
                }
                .padding(.vertical, 4)
                ForEach(shown) { t in
                    RowLine()
                    columns {
                        Text(t.index > 0 ? "\(t.index)" : "").foregroundStyle(SpendStyle.text3).cell(padding: 0)
                        Text(Self.time.string(from: t.start)).foregroundStyle(SpendStyle.text3).cell()
                        Text(t.prompt.isEmpty ? "(before your first message)" : t.prompt)
                            .truncationMode(.tail)
                            .foregroundStyle(t.prompt.isEmpty ? SpendStyle.text3 : SpendStyle.text)
                            .padding(.trailing, 10)
                            .cell()
                        Text("\(t.answers)").cell(.trailing)
                        Text(Format.dollars(t.totalCostMicros)).fontWeight(.medium).cell(.trailing)
                    }
                    .padding(.vertical, 6)
                    .font(.system(size: SpendStyle.row))
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .help(help(t))
                }
            }
            if turns.count > shownAtFirst {
                MoreButton(title: showAll ? "Show fewer" : "Show \(turns.count - shownAtFirst) more") { showAll.toggle() }
            }
        }
    }

    private func help(_ t: Turn) -> String {
        var lines = [t.prompt, ""]
        lines.append("Main session: \(Format.dollars(t.costMicros)) in \(t.answers) model calls, \(t.toolCalls) tool calls")
        if !t.subagents.isEmpty {
            lines.append("Subagents: \(Format.dollars(t.subagentCostMicros)) in \(t.subagents.count)")
        }
        lines.append("Total: \(Format.dollars(t.totalCostMicros)), \(Format.percent(anatomy.spend.share(t.totalCostMicros))) of the session")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Bash commands

/// Bash calls by the program they ran. A row opens the list of its calls;
/// a call opens its input, output and consumption.
struct CommandTable: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let anatomy: Anatomy
    @State private var showAll = false
    @State private var open: Set<String> = []
    @State private var shownCall: CallRef?

    var body: some View {
        let spend = anatomy.spend
        let shown = showAll ? spend.commands : Array(spend.commands.prefix(12))
        let rows = shown.map { g in
            (g: g, cells: [g.group, "\(g.calls)", added(g).map { Format.tokens($0) } ?? "", "\(g.errors)", Format.dollars(g.costMicros)])
        }
        let columns = Self.columns(rows.map(\.cells))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Bash commands", note: "by program. Click a program to see each call.")
                .help("Bash calls by the program they ran (after `cd <folder> &&`). Cost: the model calls after their results. Context added: tokens the output put into the context (estimated). Click a call to see its whole input and output.")
            VStack(spacing: 0) {
                AutoColumns(maxContent: columns) {
                    ColumnTitle("Program").padding(.leading, Self.chevronWidth).cell(padding: 0)
                    ColumnTitle("Calls").cell(.trailing)
                    ColumnTitle("Context added").cell(.trailing)
                    ColumnTitle("Errors").cell(.trailing)
                    ColumnTitle("Cost").cell(.trailing)
                }
                .padding(.vertical, 4)
                ForEach(rows, id: \.g.id) { row in
                    let g = row.g
                    let isOpen = open.contains(g.group)
                    RowLine()
                    AutoColumns(maxContent: columns) {
                        HStack(spacing: 0) {
                            // Shows that a click opens the program's calls.
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(SpendStyle.text3)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .frame(width: Self.chevronWidth, alignment: .leading)
                                .accessibilityHidden(true)
                            Text(row.cells[0]).font(.system(size: SpendStyle.row, design: .monospaced))
                        }
                        .cell(padding: 0)
                        Text(row.cells[1]).cell(.trailing)
                        Text(row.cells[2]).cell(.trailing)
                        Text(row.cells[3]).cell(.trailing)
                        Text(row.cells[4]).fontWeight(.medium).cell(.trailing)
                    }
                    .padding(.vertical, 6)
                    .font(.system(size: SpendStyle.row))
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .help(help(g))
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                    .onTapGesture { toggle(g) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(isOpen ? "Open" : "Closed")
                    .rowMenu(view: { toggle(g) },
                             goTo: g.items.first.map { first in
                                 { model.openInChat(ChatPlace(lane: first.lane, event: first.event)) }
                             },
                             fileName: RowExport.fileName(sessionID: session.id, name: "bash \(g.group)"),
                             json: { try RowExport.encode(RowExport.program(g, in: anatomy)) })
                    if isOpen {
                        CallList(anatomy: anatomy, items: g.items, shownCall: $shownCall)
                            .padding(.bottom, 6)
                    }
                }
            }
            if spend.commands.count > 12 {
                MoreButton(title: showAll ? "Show fewer" : "Show all \(spend.commands.count)") { showAll.toggle() }
            }
        }
        .sheet(item: $shownCall) { ref in
            if let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                CallSheet(sessionID: session.id, lane: lane, index: ref.index)
            }
        }
    }

    private func toggle(_ g: CCOPKit.CommandGroup) {
        withAnimation(.easeOut(duration: 0.15)) {
            if open.contains(g.group) { open.remove(g.group) } else { open.insert(g.group) }
        }
    }

    /// The room for the chevron before a program's name.
    private static let chevronWidth: CGFloat = 15

    /// The max-content width of each column (header and cells, with the cells' 1 pt padding),
    /// as an HTML table with `width: 100%` and no set widths measures them.
    private static func columns(_ rows: [[String]]) -> [CGFloat] {
        let header = NSFont.systemFont(ofSize: 11, weight: .medium)
        let mono = NSFont.monospacedSystemFont(ofSize: SpendStyle.row, weight: .regular)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: SpendStyle.row, weight: .regular)
        let digitsBold = NSFont.monospacedDigitSystemFont(ofSize: SpendStyle.row, weight: .medium)
        let titles = ["Program", "Calls", "Context added", "Errors", "Cost"]
        return titles.indices.map { i in
            let font = i == 0 ? mono : (i == 4 ? digitsBold : digits)
            let widest = rows.map { SpendStyle.width($0[i], font) }.max() ?? 0
            return max(widest, SpendStyle.width(titles[i], header)) + (i == 0 ? chevronWidth : 2)
        }
    }

    /// Tokens the group's outputs put into the context (estimated), from each call's event.
    private func added(_ g: CCOPKit.CommandGroup) -> UInt64? {
        var sum: UInt64 = 0
        var any = false
        for item in g.items {
            if let lane = anatomy.lane(item.lane), lane.events.indices.contains(item.event),
               let a = lane.events[item.event].addedTokens {
                sum += a
                any = true
            }
        }
        return any ? sum : nil
    }

    private func help(_ g: CCOPKit.CommandGroup) -> String {
        var lines = [
            "\(Format.dollars(g.costMicros)), \(Format.percent(anatomy.spend.share(g.costMicros))) of the session",
            "Avg output: \(Format.bytes(g.calls == 0 ? 0 : g.resultBytes / g.calls))",
        ]
        if let ex = g.example { lines.append("Example: \(ex)") }
        lines.append(open.contains(g.group) ? "Click to hide the calls." : "Click to see each call.")
        return lines.joined(separator: "\n")
    }
}

/// HTML table auto layout: when the columns' max-content widths fit, the extra width goes to
/// every column in proportion to its max-content width. When they do not fit, the first column
/// gives up its width.
private struct AutoColumns: Layout {
    var maxContent: [CGFloat]

    private func widths(_ width: CGFloat) -> [CGFloat] {
        let sum = maxContent.reduce(0, +)
        guard sum > 0 else { return maxContent }
        if width >= sum { return maxContent.map { $0 * width / sum } }
        var w = maxContent
        w[0] = max(0, width - (sum - maxContent[0]))
        return w
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? maxContent.reduce(0, +)
        let h = zip(subviews, widths(width)).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (s, w) in zip(subviews, widths(bounds.width)) {
            s.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w
        }
    }
}

/// The calls of one program: when, which agent, the command, and what each one cost.
struct CallList: View {
    @Environment(AppModel.self) private var model
    let anatomy: Anatomy
    let items: [CallCost]
    @Binding var shownCall: CallRef?
    @State private var byCost = false

    var body: some View {
        let rows = (byCost ? items.sorted { $0.costMicros > $1.costMicros } : items).compactMap { item -> CallRow.Values? in
            guard let lane = anatomy.lane(item.lane), lane.events.indices.contains(item.event) else { return nil }
            let e = lane.events[item.event]
            return CallRow.Values(
                item: item,
                time: e.start.formatted(date: .omitted, time: .standard),
                agent: lane.name,
                command: e.command ?? e.text ?? e.label,
                isError: e.isError,
                output: e.resultBytes.map { Format.bytes($0) } ?? "",
                added: e.addedTokens.map { Format.tokens($0) } ?? "",
                cost: Format.dollars(item.costMicros),
                help: [e.text, e.command, e.error].compactMap { $0 }.joined(separator: "\n\n"))
        }
        let widths = CallRow.Widths(rows)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(items.count) calls. Added: tokens the output put into the context (estimated). Cost: its part of the model call after it.")
                    .font(.system(size: 11)).foregroundStyle(SpendStyle.text3)
                Spacer()
                Segmented(options: [(false, "By time"), (true, "By cost")], selection: $byCost, height: 20)
                    .frame(width: 160)
            }
            LazyVStack(spacing: 0) {
                CallRow.columns(widths) {
                    ColumnTitle("Time")
                    ColumnTitle("Agent")
                    ColumnTitle("Command")
                    ColumnTitle("Output")
                    ColumnTitle("Added")
                    ColumnTitle("Cost")
                }
                .padding(.horizontal, CallRow.inset)
                .padding(.bottom, 3)
                ForEach(rows, id: \.item) { row in
                    let item = row.item
                    let event = anatomy.lane(item.lane)?.events[item.event]
                    CallRow(values: row, widths: widths) { open(item, full: event?.hasFullCall == true) }
                        .rowMenu(view: event?.hasFullCall == true ? { open(item, full: true) } : nil,
                                 goTo: { model.openInChat(ChatPlace(lane: item.lane, event: item.event)) },
                                 fileName: RowExport.fileName(sessionID: anatomy.sessionId, name: "\(event?.label ?? "call") \(row.time)"),
                                 json: {
                                     guard let lane = anatomy.lane(item.lane) else { throw CocoaError(.fileNoSuchFile) }
                                     return try RowExport.encode(await model.callExport(sessionID: anatomy.sessionId, lane: lane, event: item.event))
                                 })
                }
            }
        }
        .padding(10)
        .background(SpendStyle.soft, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SpendStyle.line2))
    }
}

extension CallList {
    /// A tool call opens in the call sheet. A prompt or a model call has no
    /// such sheet, so it opens in Chat.
    fileprivate func open(_ item: CallCost, full: Bool) {
        if full {
            shownCall = CallRef(lane: item.lane, index: item.event)
        } else {
            model.openInChat(ChatPlace(lane: item.lane, event: item.event))
        }
    }
}

/// One call in the list of a program. The whole row lights up under the
/// pointer, to show that a click opens this call in full.
private struct CallRow: View {
    struct Values {
        var item: CallCost
        var time: String
        var agent: String
        var command: String
        var isError: Bool
        var output: String
        var added: String
        var cost: String
        var help: String
    }

    /// Every column but Command, which takes the rest. As wide as the widest
    /// value or title; an agent's name at most 160.
    struct Widths {
        var time: CGFloat
        var agent: CGFloat
        var output: CGFloat
        var added: CGFloat
        var cost: CGFloat

        init(_ rows: [Values]) {
            let title = NSFont.systemFont(ofSize: 11, weight: .medium)
            let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let bold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            func width(_ name: String, _ font: NSFont, _ value: KeyPath<Values, String>) -> CGFloat {
                max(SpendStyle.width(name, title), rows.map { SpendStyle.width($0[keyPath: value], font) }.max() ?? 0)
            }
            time = width("Time", digits, \.time)
            agent = min(160, width("Agent", digits, \.agent))
            output = width("Output", digits, \.output)
            added = width("Added", digits, \.added)
            cost = width("Cost", bold, \.cost)
        }
    }

    /// How far the highlight reaches past the text.
    static let inset: CGFloat = 5

    let values: Values
    let widths: Widths
    let action: () -> Void
    @State private var hovering = false

    /// Six cells in the columns: Time, Agent, Command, Output, Added, Cost.
    static func columns<A: View, B: View, C: View, D: View, E: View, F: View>(
        _ w: Widths, @ViewBuilder cells: () -> TupleView<(A, B, C, D, E, F)>) -> some View {
        let c = cells().value
        return HStack(spacing: 12) {
            c.0.frame(width: w.time, alignment: .trailing)
            c.1.frame(width: w.agent, alignment: .leading)
            c.2.frame(maxWidth: .infinity, alignment: .leading)
            c.3.frame(width: w.output, alignment: .trailing)
            c.4.frame(width: w.added, alignment: .trailing)
            c.5.frame(width: w.cost, alignment: .trailing)
        }
    }

    var body: some View {
        Self.columns(widths) {
            Text(values.time).foregroundStyle(SpendStyle.text3)
            Text(values.agent).lineLimit(1)
            Text(values.command).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                .foregroundStyle(values.isError ? Theme.bad : SpendStyle.text)
            Text(values.output)
            Text(values.added)
            Text(values.cost).fontWeight(.medium)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 2)
        .background(hovering ? SpendStyle.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .help(values.help)
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // A row can go away under the pointer: the list closes or sorts again.
        .onDisappear {
            if hovering { NSCursor.pop() }
            hovering = false
        }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows this call in full")
    }
}
