import CCOPKit
import SwiftUI

// The Chat tab follows the design board `WindowChat`: CSS px are points here.

/// Black in light mode, white in dark mode, at an alpha: the board's
/// `rgba(0,0,0,a)` lines and tints.
private func ink(_ alpha: CGFloat) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: alpha) : NSColor(white: 0, alpha: alpha)
    })
}

/// The board's colour tokens.
private enum Board {
    /// `--bg`: the page.
    static let bg = Theme.page
    /// `--soft`: the opaque filter bar (it is pinned over the messages) and the tool footer.
    static let soft = Theme.dynamic(0xF7F7F8, 0x262628)
    /// `--line`, `--line2`: borders.
    static let line = ink(0.10)
    static let line2 = ink(0.06)
    /// `--text2`, `--text3`.
    static let text2 = Theme.dynamic(0x5F5F64, 0xB9B9BF)
    static let text3 = Theme.dynamic(0x6E6E73, 0xA1A1A8)
    /// A chip that is on: dark fill and white text (inverted in dark mode).
    static let chipOn = Theme.dynamic(0x1D1D1F, 0xF2F2F7)
    static let chipOnText = Theme.dynamic(0xFFFFFF, 0x1D1D1F)
    /// Claude's avatar: the symbol, and the tint behind it.
    static let claude = Theme.dynamic(0xC2410C, 0xFB923C)
    static let claudeTint = Theme.dynamic(0xD97757, 0xD97757)
    /// The dark box that shows a tool's output, in both modes.
    static let outputBackground = Theme.dynamic(0x1D1D1F, 0x111113)
    static let outputText = Color(nsColor: NSColor(rgb: 0xE5E5EA))
    static let outputErrorText = Color(nsColor: NSColor(rgb: 0xFF8A80))
}

/// The width of the avatar column, and the space after it.
private let avatarSize: CGFloat = 28
private let avatarGap: CGFloat = 12
/// The message column: at most 860 wide with its 24 padding on each side.
private let columnWidth: CGFloat = 860 - 2 * 24

/// SwiftUI adds no leading above the first line and below the last one; CSS
/// `line-height` does (half above, half below). These give the same height.
/// 13 pt system: 16 pt natural line. 11 pt mono: 13 pt.
private enum LineHeight {
    /// `line-height: 1.45` at 13 px (the prompt bubble).
    static let prompt: CGFloat = 13 * 1.45 - 16
    /// `line-height: 1.5` at 13 px (Claude's text).
    static let answer: CGFloat = 13 * 1.5 - 16
    /// `line-height: 1.55` at 11 px mono (the tool output).
    static let output: CGFloat = 11 * 1.55 - 13
}

/// The Chat tab: one lane's messages as in the chat, each with what it cost.
/// The texts come from `ccop chat`; the tokens and costs from the anatomy.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let anatomy: Anatomy
    @State private var laneID = "main"
    @State private var chat: Loadable<LaneChat> = .loading
    @State private var shownCall: CallRef?
    @State private var openTools: Set<Int> = []
    @State private var expandAll = false
    @State private var filter = ChatFilter()

    var body: some View {
        let lane = anatomy.lane(laneID) ?? anatomy.lanes[0]
        // A ScrollView at the root, as in the other tabs; the filter bar stays at the top.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    switch chat {
                    case .loading:
                        ProgressView("Reading the messages…").frame(maxWidth: .infinity).padding(40)
                    case let .failed(why):
                        Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
                            .frame(maxWidth: .infinity).padding(40)
                    case let .loaded(c):
                        messages(lane, texts: c.byEvent, shown: filter.indices(lane.events))
                        Color.clear.frame(height: 28)
                    }
                } header: {
                    filterBar(lane)
                }
            }
        }
        .task(id: "\(lane.id) \(lane.events.count)") {
            if case .loaded = chat {} else { chat = .loading }
            switch await model.chat(session.id, lane: lane.id) {
            case let .success(c): chat = .loaded(c)
            case let .failure(e): chat = .failed(e.localizedDescription)
            }
        }
        .onChange(of: laneID) {
            chat = .loading
            openTools = []
        }
        .sheet(item: $shownCall) { ref in
            if let l = anatomy.lane(ref.lane), l.events.indices.contains(ref.index) {
                CallSheet(sessionID: session.id, lane: l, index: ref.index)
            }
        }
    }

    // MARK: - Filter bar

    /// One wrapping row, as `flex-wrap: wrap; gap: 8px 10px`; the summary is
    /// pushed to the right end of its line.
    private func filterBar(_ lane: AnatomyLane) -> some View {
        FlowBar(hSpacing: 10, vSpacing: 8) {
            lanePicker(lane)
            Rectangle().fill(Board.line).frame(width: 1, height: 18)
            Text("Show").font(.system(size: 11)).foregroundStyle(Board.text3)
            ForEach(ChatFilter.Kind.allCases) { k in
                Toggle(k.title, isOn: Binding(
                    get: { filter.kinds.contains(k) },
                    set: { on in if on { filter.kinds.insert(k) } else { filter.kinds.remove(k) } }
                ))
                .toggleStyle(ChipToggleStyle())
            }
            Toggle("Top 10% by cost", isOn: $filter.topCosts)
                .toggleStyle(ChipToggleStyle())
                .help("Only the most expensive 10% of the messages the other filters show (of all messages when none is on).")
            Toggle("Tool output", isOn: $expandAll)
                .toggleStyle(ChipToggleStyle())
                .help("Open every tool call to show its output.")
            if filter.isOn {
                Button("Clear") { filter = ChatFilter() }.buttonStyle(.link).font(.system(size: 12))
                Text("\(filter.indices(lane.events).count) of \(lane.events.count)")
                    .font(.system(size: 11)).foregroundStyle(Board.text3).monospacedDigit()
                    .help("Messages shown of all messages in this lane")
            }
            summary(lane).layoutValue(key: PushRight.self, value: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Board.soft)
        .overlay(alignment: .bottom) { Rectangle().fill(Board.line2).frame(height: 1) }
    }

    /// A chip with the lane's name and a down chevron; it opens the list of lanes.
    private func lanePicker(_ lane: AnatomyLane) -> some View {
        Menu {
            Picker("Lane", selection: $laneID) {
                ForEach(anatomy.lanesInTreeOrder) { l in
                    let cost = anatomy.spend.lane(l.id).map { " · \(Format.dollars($0.costMicros))" } ?? ""
                    Text(String(repeating: "    ", count: anatomy.depth(of: l)) + l.name + cost).tag(l.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(lane.id == "main" ? "Main" : lane.name).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Board.bg))
            .overlay(Capsule().strokeBorder(Board.line))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The lane to show: the main chat or one subagent")
    }

    @ViewBuilder
    private func summary(_ lane: AnatomyLane) -> some View {
        if let spend = anatomy.spend.lane(lane.id) {
            Text("\(Format.dollars(spend.costMicros)) · \(spend.modelCalls) model calls · \(Format.tokens(spend.avgContext)) context on average")
                .font(.system(size: 11)).foregroundStyle(Board.text3).monospacedDigit()
                .lineLimit(1)
                .help("Each model call reads the whole context again: its line shows what it read, what it wrote, and its cost. A tool result shows what it added to the context and its part of the next call. Thinking text is not saved in the transcript; its tokens are in the output.")
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private func messages(_ lane: AnatomyLane, texts: [Int: ChatText], shown: [Int]) -> some View {
        let prompts = promptNumbers(lane)
        if shown.isEmpty {
            Text("No messages match the filter.").font(.system(size: 13)).foregroundStyle(Board.text3)
                .frame(maxWidth: .infinity).padding(40)
        }
        ForEach(Array(shown.enumerated()), id: \.element) { pos, i in
            let e = lane.events[i]
            let previous = pos > 0 ? lane.events[shown[pos - 1]].kind : nil
            let first = pos == 0
            switch e.kind {
            case .prompt:
                promptView(lane, e, texts[i], number: prompts[i] ?? 0, first: first)
            case .answer:
                // An answer after a prompt (or at the top) starts Claude's block with
                // the avatar; the next answers of the same block show only their line.
                let starts = previous == nil || previous == .prompt || previous == .compact || previous == .error
                answerView(e, texts[i], startsBlock: starts, first: first)
            case .tool:
                toolView(lane, i, e, texts[i], first: first)
            case .compact:
                marker(e.text ?? "Compacted", first: first)
            case .error:
                marker(e.text ?? "API error", first: first)
            }
        }
    }

    /// The number of each prompt in its lane, from 1.
    private func promptNumbers(_ lane: AnatomyLane) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for i in lane.events.indices where lane.events[i].kind == .prompt { out[i] = out.count + 1 }
        return out
    }

    /// One row of the message column: an avatar (or its empty space) and the
    /// content. Rows are 14 apart; the parts of one Claude block 8 apart.
    private func row(avatar: Avatar?, top: CGFloat, first: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: avatarGap) {
            if let avatar { avatar } else { Color.clear.frame(width: avatarSize, height: 1) }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: columnWidth, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, first ? 20 : top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promptView(_ lane: AnatomyLane, _ e: AnatomyEvent, _ t: ChatText?, number: Int, first: Bool) -> some View {
        let main = lane.id == "main"
        let color = main ? Theme.prompt : Theme.agent
        let time = e.start.formatted(date: .omitted, time: .standard)
        let avatar = main
            ? Avatar(symbol: "person.fill", color: color, tint: color.opacity(0.12), size: 14, label: "You")
            : Avatar(symbol: Theme.tool("Agent").symbol, color: color, tint: color.opacity(0.12), size: 12, label: "The lead")
        return row(avatar: avatar, top: 14, first: first) {
            VStack(alignment: .leading, spacing: 4) {
                Text(main ? "Prompt \(number) · \(time)" : "Task from the lead · \(time)")
                    .font(.system(size: 11)).foregroundStyle(Board.text3).monospacedDigit()
                Text(t?.text ?? e.text ?? "")
                    .font(.system(size: 13))
                    .lineSpacing(LineHeight.prompt)
                    .padding(.vertical, LineHeight.prompt / 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.16)))
                if let line = promptCostLine(e) {
                    Text(line)
                        .font(.system(size: 11)).foregroundStyle(Board.text3).monospacedDigit()
                        .help("Tokens this prompt added to the context (estimated); every later call of this lane reads them again. The cost is its part of the model call after it.")
                }
            }
        }
    }

    private func promptCostLine(_ e: AnatomyEvent) -> String? {
        var parts: [String] = []
        if let added = e.addedTokens, added > 0 { parts.append("+\(Format.tokens(added)) tokens to context") }
        if let paid = e.costMicros, paid > 0 { parts.append(Format.dollars(paid)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func answerView(_ e: AnatomyEvent, _ t: ChatText?, startsBlock: Bool, first: Bool) -> some View {
        let u = e.usage ?? TokenUsage()
        let read = u.inputTokens + u.cacheWriteTokens + u.cacheReadTokens
        let caption = [e.start.formatted(date: .omitted, time: .standard),
                       "read \(Format.tokens(read))", "wrote \(Format.tokens(u.outputTokens))",
                       Format.dollars(e.costMicros ?? 0)].joined(separator: " · ")
        let thinking = t?.thinking == true
        let avatar = Avatar(symbol: "sparkles", color: Board.claude, tint: Board.claudeTint.opacity(0.14), size: 14, label: "Claude")
        return row(avatar: startsBlock ? avatar : nil, top: startsBlock ? 14 : 8, first: first) {
            VStack(alignment: .leading, spacing: 8) {
                if thinking, !startsBlock { thinkingLine(u.outputTokens) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if startsBlock { Text("Claude").font(.system(size: 13, weight: .semibold)) }
                    Text(caption)
                        .font(.system(size: 11)).foregroundStyle(Board.text3).monospacedDigit()
                        .help("\(e.model.map { "Model: \($0). " } ?? "")Read: cache read \(Format.tokens(u.cacheReadTokens)), cache write \(Format.tokens(u.cacheWriteTokens)), input \(Format.tokens(u.inputTokens)). Wrote: output tokens, with thinking.")
                }
                if thinking, startsBlock { thinkingLine(u.outputTokens) }
                if let text = t?.text, !text.isEmpty {
                    Self.richText(text)
                        .font(.system(size: 13))
                        .lineSpacing(LineHeight.answer)
                        .padding(.vertical, LineHeight.answer / 2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Claude's text with its inline Markdown: `code` in mono 12 on a light
    /// tint, as on the board; bold, italics and links as Markdown says.
    private static func richText(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard var a = try? AttributedString(markdown: s, options: options) else { return Text(s) }
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 12, design: .monospaced)
            a[run.range].backgroundColor = ink(0.05)
        }
        return Text(a)
    }

    /// The transcript keeps no thinking text and no separate count of its tokens.
    private func thinkingLine(_ wrote: UInt64) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 11))
            Text("thinking · its tokens are part of the \(Format.tokens(wrote)) written (text not saved)").monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(Board.text3)
        .help("This call had thinking blocks. Their text is not saved; their tokens are in the output.")
    }

    @ViewBuilder
    private func toolView(_ lane: AnatomyLane, _ i: Int, _ e: AnatomyEvent, _ t: ChatText?, first: Bool) -> some View {
        if let agent = e.agentId, let sub = anatomy.lane(agent) {
            row(avatar: nil, top: 8, first: first) {
                SubagentCard(lane: sub, spend: anatomy.spend.lane(sub.id), event: e,
                             openChat: { laneID = agent },
                             openCall: { shownCall = CallRef(lane: lane.id, index: i) })
            }
        } else {
            row(avatar: nil, top: 8, first: first) {
                ToolCallRow(lane: lane, index: i, text: t, isOpen: expandAll || openTools.contains(i),
                            toggle: { if openTools.contains(i) { openTools.remove(i) } else { openTools.insert(i) } },
                            openCall: { shownCall = CallRef(lane: lane.id, index: i) })
            }
        }
    }

    private func marker(_ text: String, first: Bool) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.bad.opacity(0.5)).frame(height: 1)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.bad).fixedSize()
            Rectangle().fill(Theme.bad.opacity(0.5)).frame(height: 1)
        }
        .frame(maxWidth: columnWidth)
        .padding(.horizontal, 24)
        .padding(.top, first ? 20 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Parts

/// Lays its children out in lines like `flex-wrap: wrap`, each line centred
/// vertically. A child marked `PushRight` goes to the right end of its line,
/// as after a `flex-grow` spacer; when it does not fit it starts the next line.
private struct FlowBar: Layout {
    var hSpacing: CGFloat
    var vSpacing: CGFloat

    private struct Line { var items: [(index: Int, size: CGSize)] = []; var height: CGFloat = 0 }

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [Line] {
        var out: [Line] = [Line()]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !out[out.count - 1].items.isEmpty, x + hSpacing + size.width > width {
                out.append(Line())
                x = 0
            }
            x += (out[out.count - 1].items.isEmpty ? 0 : hSpacing) + size.width
            out[out.count - 1].items.append((i, size))
            out[out.count - 1].height = max(out[out.count - 1].height, size.height)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let ls = lines(width, subviews)
        let height = ls.map(\.height).reduce(0, +) + vSpacing * CGFloat(max(0, ls.count - 1))
        let used = ls.map { l in l.items.map(\.size.width).reduce(0, +) + hSpacing * CGFloat(max(0, l.items.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(bounds.width, subviews) {
            var x = bounds.minX
            for (n, (i, size)) in line.items.enumerated() {
                // Alone at the start of a line, it stays left, as in CSS.
                let push = subviews[i][PushRight.self] && n > 0
                let left = push ? max(x, bounds.maxX - size.width) : x
                subviews[i].place(at: CGPoint(x: left, y: y + (line.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x = left + size.width + hSpacing
            }
            y += line.height + vSpacing
        }
    }
}

private struct PushRight: LayoutValueKey {
    static let defaultValue = false
}

/// A round avatar with a symbol on a light tint.
private struct Avatar: View {
    let symbol: String
    let color: Color
    let tint: Color
    let size: CGFloat
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .frame(width: avatarSize, height: avatarSize)
            .background(tint, in: Circle())
            .accessibilityLabel(label)
    }
}

/// The board's `.ico`: a rounded square (radius 6) with a tool's symbol on a tint of its colour.
private struct ToolIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24
    var glyph: CGFloat = 11

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

/// The board's `.chip`: outlined on the page colour when off, filled dark when on.
private struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(on ? Board.chipOnText : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(on ? Board.chipOn : Board.bg))
                .overlay(Capsule().strokeBorder(on ? Board.chipOn : Board.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A small bordered button on the page colour, as "Open the whole call".
private struct BoardButton: View {
    let title: String
    var height: CGFloat = 24
    var color: Color = .primary
    var border: Color = Board.line
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: height)
                .background(Board.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// One tool call as a compact row. Open, it shows the first lines of the output,
/// what the call cost, and a button to open the whole call.
private struct ToolCallRow: View {
    let lane: AnatomyLane
    let index: Int
    let text: ChatText?
    let isOpen: Bool
    let toggle: () -> Void
    let openCall: () -> Void
    @State private var hovering = false

    /// The output lines shown in the row; the whole output is in the call sheet.
    static let shownLines = 12
    /// At least this many tokens added makes the cost red.
    static let bigAddition: UInt64 = 10_000

    private var event: AnatomyEvent { lane.events[index] }

    var body: some View {
        let e = event
        let shape = RoundedRectangle(cornerRadius: isOpen ? 10 : 8)
        let border = e.isError ? Theme.bad.opacity(0.3) : (isOpen ? Board.line : ink(0.08))
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen { details }
        }
        .background(Board.bg)
        .clipShape(shape)
        .overlay(shape.strokeBorder(border))
    }

    private var header: some View {
        let e = event
        let style = Theme.tool(e.tool ?? "")
        let big = (e.addedTokens ?? 0) >= Self.bigAddition
        return HStack(spacing: 10) {
            ToolIcon(symbol: style.symbol, color: style.color)
            Text(e.label).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
            Text(e.command ?? e.text ?? "")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Board.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if e.isError { ErrorBadge() }
            if let line = costLine {
                Text(line)
                    .font(.system(size: 11, weight: big ? .semibold : .regular))
                    .foregroundStyle(big ? Theme.bad : Board.text3)
                    .monospacedDigit()
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Board.text3)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(isOpen || hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Board.soft : (e.isError ? Theme.bad.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isOpen ? "Close" : "Open", toggle)
        .help(helpText)
    }

    /// `+31K · $0.34`: tokens added to the context, and the part of the next call.
    private var costLine: String? {
        var parts: [String] = []
        if let added = event.addedTokens, added > 0 { parts.append("+\(Format.tokens(added))") }
        if let paid = event.costMicros { parts.append(Format.dollars(paid)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var helpText: String {
        let e = event
        var lines: [String] = []
        if let b = e.resultBytes { lines.append("Output: \(Format.bytes(b)).") }
        if let added = e.addedTokens { lines.append("Added to the context: \(Format.tokens(added)) tokens (estimated). Every later call of this lane reads them again.") }
        if let tokens = e.paidTokens, tokens > 0 {
            lines.append("Its part of the next model call: \(Format.tokens(tokens)) tokens, \(Format.dollars(e.costMicros ?? 0)). When several results came back before one call, the call is split evenly between them.")
        }
        if e.isError, let error = e.error { lines.append("Error: \(error)") }
        lines.append("Click to show the output.")
        return lines.joined(separator: "\n")
    }

    private var details: some View {
        let e = event
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(longInput, id: \.name) { f in
                inputBox(f.name, f.text)
            }
            if let out = text?.output {
                outputBox(out, truncated: text?.outputTruncated == true, error: e.isError)
            } else if text != nil {
                Text(e.resultBytes == nil ? "No result yet." : "No output text saved.")
                    .font(.system(size: 11)).foregroundStyle(Board.text3)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Board.line2).frame(height: 1) }
            }
            HStack(spacing: 10) {
                Text(footerText)
                    .font(.system(size: 11)).foregroundStyle(Board.text3).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BoardButton(title: "Open the whole call", action: openCall)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Board.soft)
            .overlay(alignment: .top) { Rectangle().fill(Board.line2).frame(height: 1) }
        }
    }

    /// Input fields too long for the one line in the header.
    private var longInput: [(name: String, text: String)] {
        (text?.input?.fields ?? []).filter { $0.text.contains("\n") || $0.text.count > 120 }
    }

    private func inputBox(_ name: String, _ value: String) -> some View {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(8).map { String($0.prefix(400)) }.joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Board.text3)
            Text(shown + (lines.count > 8 ? "\n… \(lines.count - 8) more lines" : ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Board.text2)
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Board.soft)
        .overlay(alignment: .top) { Rectangle().fill(Board.line2).frame(height: 1) }
    }

    private func outputBox(_ out: String, truncated: Bool, error: Bool) -> some View {
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(Self.shownLines).map { String($0.prefix(400)) }
        let more = lines.count - shown.count
        return VStack(alignment: .leading, spacing: LineHeight.output) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(error ? Board.outputErrorText : Board.outputText)
            }
            if more > 0 || truncated {
                Text(more > 0 ? "… \(more.formatted()) more lines" : "…")
                    .foregroundStyle(Board.outputText)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, LineHeight.output / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Board.outputBackground)
    }

    /// `This output stayed in the context for 57 more calls. Its part of the next call: $0.34.`
    private var footerText: String {
        let e = event
        let what = e.isError ? "error" : "output"
        var parts: [String] = []
        if let added = e.addedTokens, added > 0 {
            if let calls = lane.readingCalls(after: index), calls.count > 1 {
                let more = calls.count - 1
                let until = calls.upperBound < lane.context.count ? ", until a compaction" : ""
                parts.append("This \(what) stayed in the context for \(more) more \(more == 1 ? "call" : "calls")\(until).")
            } else {
                parts.append("This \(what) added \(Format.tokens(added)) tokens to the context.")
            }
        }
        if let paid = e.costMicros { parts.append("Its part of the next call: \(Format.dollars(paid)).") }
        return parts.isEmpty ? "No model call came after this result." : parts.joined(separator: " ")
    }
}

/// The red `error` badge of a call.
private struct ErrorBadge: View {
    var body: some View {
        Text("error")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.bad)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A subagent started by an `Agent` call: its name, what it was and cost, and
/// a button to show its own chat. The Agent call itself opens from the context menu.
private struct SubagentCard: View {
    let lane: AnatomyLane
    let spend: LaneSpend?
    let event: AnatomyEvent
    let openChat: () -> Void
    let openCall: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        HStack(spacing: 12) {
            ToolIcon(symbol: Theme.tool("Agent").symbol, color: Theme.agent, size: 28, glyph: 13)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Subagent: \(lane.name)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if event.isError { ErrorBadge() }
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(Board.text3).monospacedDigit().lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BoardButton(title: "Open this subagent's chat", height: 26, color: Theme.agent,
                        border: Theme.agent.opacity(0.35), action: openChat)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.agent.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(Theme.agent.opacity(0.25)))
        .contentShape(shape)
        .contextMenu {
            Button("Open the whole call", action: openCall)
            Button("Open this subagent's chat", action: openChat)
        }
        .help(resultHelp)
    }

    /// `Explore · haiku · 21 calls · 7 min · $0.21`.
    private var caption: String {
        let calls = spend?.modelCalls ?? UInt64(lane.events.filter { $0.kind == .answer }.count)
        var parts: [String] = []
        if let type = lane.agentType, !type.isEmpty { parts.append(type) }
        if let model = lane.model.flatMap(modelFamily) { parts.append(model) }
        parts.append("\(calls) \(calls == 1 ? "call" : "calls")")
        if lane.duration > 0 { parts.append(minutes(lane.duration)) }
        if let spend { parts.append(Format.dollars(spend.costMicros)) }
        return parts.joined(separator: " · ")
    }

    private var resultHelp: String {
        var parts: [String] = []
        if let model = lane.model { parts.append("Model: \(model).") }
        if let added = event.addedTokens, added > 0 { parts.append("Its result added \(Format.tokens(added)) tokens to this lane's context.") }
        if let paid = event.costMicros { parts.append("Its part of the next call: \(Format.dollars(paid)).") }
        parts.append("Right-click to open the whole Agent call: the task it got and the result it returned.")
        return parts.joined(separator: " ")
    }

    /// `claude-haiku-4-5-20251001` → `haiku`; the full id is in the help text.
    private func modelFamily(_ model: String) -> String? {
        guard !model.isEmpty, model != "<synthetic>" else { return nil }
        let m = model.hasPrefix("claude-") ? String(model.dropFirst(7)) : model
        return m.split(separator: "-").first { !$0.allSatisfy(\.isNumber) }.map(String.init) ?? m
    }

    /// `48 s`, `7 min`, `1 h 05 min`.
    private func minutes(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return Format.duration(seconds) }
        let m = Int((seconds / 60).rounded())
        return m < 60 ? "\(m) min" : String(format: "%d h %02d min", m / 60, m % 60)
    }
}
