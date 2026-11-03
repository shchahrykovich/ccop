import CCOPKit
import SwiftUI

/// The color of Claude's avatar.
private let claudeColor = Theme.dynamic(0xC2410C, 0xFB923C)
/// The opaque soft background of the filter bar (it is pinned over the messages).
private let barBackground = Theme.dynamic(0xF7F7F8, 0x262628)
/// The dark box that shows a tool's output, in both modes.
private let outputBackground = Theme.dynamic(0x1D1D1F, 0x111113)
private let outputText = Color(nsColor: NSColor(rgb: 0xE5E5EA))
private let outputErrorText = Color(nsColor: NSColor(rgb: 0xFF8A80))

/// The width of the avatar column, and the space after it.
private let avatarSize: CGFloat = 28
private let avatarGap: CGFloat = 12

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

    private func filterBar(_ lane: AnatomyLane) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    controls(lane)
                    Spacer(minLength: 12)
                    summary(lane)
                }
                VStack(alignment: .leading, spacing: 8) {
                    controls(lane)
                    summary(lane)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { lanePicker; Spacer(minLength: 0) }
                    chips(lane)
                    summary(lane)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
        }
        .background(barBackground)
    }

    private func controls(_ lane: AnatomyLane) -> some View {
        HStack(spacing: 10) {
            lanePicker
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 18)
            chips(lane)
        }
    }

    private var lanePicker: some View {
        Picker("Lane", selection: $laneID) {
            ForEach(anatomy.lanesInTreeOrder) { l in
                let cost = anatomy.spend.lane(l.id).map { " · \(Format.dollars($0.costMicros))" } ?? ""
                Text(String(repeating: "  ", count: anatomy.depth(of: l)) + l.name + cost).tag(l.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help("The lane to show: the main chat or one subagent")
    }

    private func chips(_ lane: AnatomyLane) -> some View {
        HStack(spacing: 6) {
            Text("Show").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(ChatFilter.Kind.allCases) { k in
                Toggle(k.title, isOn: Binding(
                    get: { filter.kinds.contains(k) },
                    set: { on in if on { filter.kinds.insert(k) } else { filter.kinds.remove(k) } }
                ))
            }
            Toggle("Top 10% by cost", isOn: $filter.topCosts)
                .help("Only the most expensive 10% of the messages the other filters show (of all messages when none is on).")
            Toggle("Tool output", isOn: $expandAll)
                .help("Open every tool call to show its output.")
            if filter.isOn {
                Button("Clear") { filter = ChatFilter() }.buttonStyle(.link).font(.system(size: 12))
                Text("\(filter.indices(lane.events).count) of \(lane.events.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .help("Messages shown of all messages in this lane")
            }
        }
        .toggleStyle(ChipToggleStyle())
        .fixedSize()
    }

    @ViewBuilder
    private func summary(_ lane: AnatomyLane) -> some View {
        if let spend = anatomy.spend.lane(lane.id) {
            Text("\(Format.dollars(spend.costMicros)) · \(spend.modelCalls) model calls · \(Format.tokens(spend.avgContext)) context on average")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .help("Each model call reads the whole context again: its line shows what it read, what it wrote, and its cost. A tool result shows what it added to the context and its part of the next call. Thinking text is not saved in the transcript; its tokens are in the output.")
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private func messages(_ lane: AnatomyLane, texts: [Int: ChatText], shown: [Int]) -> some View {
        let prompts = promptNumbers(lane)
        if shown.isEmpty {
            Text("No messages match the filter.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
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

    /// One row of the message column: an avatar (or its empty space) and the content.
    private func row(avatar: Avatar?, top: CGFloat, first: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: avatarGap) {
            if let avatar { avatar } else { Color.clear.frame(width: avatarSize, height: 1) }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 860, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, first ? 20 : top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promptView(_ lane: AnatomyLane, _ e: AnatomyEvent, _ t: ChatText?, number: Int, first: Bool) -> some View {
        let main = lane.id == "main"
        let color = main ? Theme.prompt : Theme.agent
        let time = e.start.formatted(date: .omitted, time: .standard)
        return row(avatar: Avatar(symbol: main ? "person.fill" : Theme.tool("Agent").symbol, color: color, label: main ? "You" : "The lead"),
                   top: 14, first: first) {
            VStack(alignment: .leading, spacing: 4) {
                Text(main ? "Prompt \(number) · \(time)" : "Task from the lead · \(time)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Text(t?.text ?? e.text ?? "")
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.18)))
                if let line = promptCostLine(e) {
                    Text(line)
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
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
        return row(avatar: startsBlock ? Avatar(symbol: "sparkles", color: claudeColor, label: "Claude") : nil,
                   top: startsBlock ? 14 : 8, first: first) {
            VStack(alignment: .leading, spacing: 6) {
                if thinking, !startsBlock { thinkingLine(u.outputTokens) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if startsBlock { Text("Claude").fontWeight(.semibold) }
                    Text(caption)
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .help("\(e.model.map { "Model: \($0). " } ?? "")Read: cache read \(Format.tokens(u.cacheReadTokens)), cache write \(Format.tokens(u.cacheWriteTokens)), input \(Format.tokens(u.inputTokens)). Wrote: output tokens, with thinking.")
                }
                .frame(minHeight: startsBlock ? avatarSize - 6 : nil, alignment: .bottom)
                if thinking, startsBlock { thinkingLine(u.outputTokens) }
                if let text = t?.text, !text.isEmpty {
                    Text(text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The transcript keeps no thinking text and no separate count of its tokens.
    private func thinkingLine(_ wrote: UInt64) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 11))
            Text("thinking · its tokens are part of the \(Format.tokens(wrote)) written (text not saved)").monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
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
        .frame(maxWidth: 860)
        .padding(.horizontal, 24)
        .padding(.top, first ? 20 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Parts

/// A round avatar with a symbol on a light tint of its color.
private struct Avatar: View {
    let symbol: String
    let color: Color
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: avatarSize, height: avatarSize)
            .background(color.opacity(0.13), in: Circle())
            .accessibilityLabel(label)
    }
}

/// A filter chip: outlined when off, filled dark when on.
private struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(configuration.isOn ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(configuration.isOn ? Color.primary : Theme.card))
                .overlay(Capsule().stroke(configuration.isOn ? Color.primary : Color.primary.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
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
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen { details }
        }
        .background(Theme.card)
        .clipShape(shape)
        .overlay(shape.stroke(e.isError ? Theme.bad.opacity(0.3) : Color.primary.opacity(0.09)))
    }

    private var header: some View {
        let e = event
        let style = Theme.tool(e.tool ?? "")
        let big = (e.addedTokens ?? 0) >= Self.bigAddition
        return HStack(spacing: 10) {
            IconTile(symbol: style.symbol, color: style.color)
            Text(e.label).fontWeight(.medium).lineLimit(1).fixedSize()
            Text(e.command ?? e.text ?? "")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if e.isError {
                Text("error")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.bad)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            if let line = costLine {
                Text(line)
                    .font(.system(size: 11, weight: big ? .semibold : .regular))
                    .foregroundStyle(big ? Theme.bad : .secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(isOpen || hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.04) : (e.isError ? Theme.bad.opacity(0.04) : .clear))
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
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            HStack(spacing: 10) {
                Text(footerText)
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open the whole call", action: openCall).controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
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
            Text(name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(shown + (lines.count > 8 ? "\n… \(lines.count - 8) more lines" : ""))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    private func outputBox(_ out: String, truncated: Bool, error: Bool) -> some View {
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(Self.shownLines).map { String($0.prefix(400)) }
        let more = lines.count - shown.count
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(error ? outputErrorText : outputText)
            }
            if more > 0 || truncated {
                Text(more > 0 ? "… \(more) more lines" : "…")
                    .foregroundStyle(outputText.opacity(0.6))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(outputBackground)
    }

    /// What this result cost: what it added, how long it stayed, its part of the next call.
    private var footerText: String {
        let e = event
        var parts: [String] = []
        if let added = e.addedTokens, added > 0 {
            parts.append("This \(e.isError ? "error" : "output") added \(Format.tokens(added)) tokens to the context.")
            if let calls = lane.readingCalls(after: index), calls.count > 1 {
                let more = calls.count - 1
                parts.append("It stayed there for \(more) more \(more == 1 ? "call" : "calls")\(calls.upperBound < lane.context.count ? ", until a compaction" : "").")
            }
        }
        if let paid = e.costMicros { parts.append("Its part of the next call: \(Format.dollars(paid)).") }
        return parts.isEmpty ? "No model call came after this result." : parts.joined(separator: " ")
    }
}

/// A subagent started by an `Agent` call: its name, what it was and cost, and
/// a button to show its own chat.
private struct SubagentCard: View {
    let lane: AnatomyLane
    let spend: LaneSpend?
    let event: AnatomyEvent
    let openChat: () -> Void
    let openCall: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        HStack(spacing: 12) {
            IconTile(symbol: Theme.tool("Agent").symbol, color: Theme.agent, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Subagent: \(lane.name)").fontWeight(.semibold).lineLimit(1)
                    if event.isError {
                        Text("error")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.bad)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Whole call", action: openCall)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help("Open the Agent call: the task it got and the result it returned")
            Button(action: openChat) {
                Text("Open this subagent's chat")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.agent)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.agent.opacity(0.35)))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.agent.opacity(0.05), in: shape)
        .overlay(shape.stroke(Theme.agent.opacity(0.25)))
        .help(resultHelp)
    }

    /// `Explore · haiku-4-5 · 21 calls · 7m 02s · $0.21`.
    private var caption: String {
        let calls = spend?.modelCalls ?? UInt64(lane.events.filter { $0.kind == .answer }.count)
        var parts: [String] = []
        if let type = lane.agentType, !type.isEmpty { parts.append(type) }
        if let model = lane.model { parts.append(shortModel(model)) }
        parts.append("\(calls) \(calls == 1 ? "call" : "calls")")
        if lane.duration > 0 { parts.append(Format.duration(lane.duration)) }
        if let spend { parts.append(Format.dollars(spend.costMicros)) }
        return parts.joined(separator: " · ")
    }

    private var resultHelp: String {
        var parts: [String] = []
        if let added = event.addedTokens, added > 0 { parts.append("Its result added \(Format.tokens(added)) tokens to this lane's context.") }
        if let paid = event.costMicros { parts.append("Its part of the next call: \(Format.dollars(paid)).") }
        return parts.joined(separator: " ")
    }

    /// `claude-haiku-4-5-20251001` → `haiku-4-5`.
    private func shortModel(_ model: String) -> String {
        var m = model.hasPrefix("claude-") ? String(model.dropFirst(7)) : model
        if let dash = m.lastIndex(of: "-"), m[m.index(after: dash)...].count == 8, m[m.index(after: dash)...].allSatisfy(\.isNumber) {
            m = String(m[..<dash])
        }
        return m
    }
}
