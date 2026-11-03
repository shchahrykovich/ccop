import CCOPKit
import SwiftUI

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
        // A ScrollView at the root, as in the other tabs; the header stays at the top.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                Section {
                    switch chat {
                    case .loading:
                        ProgressView("Reading the messages…").frame(maxWidth: .infinity).padding(40)
                    case let .failed(why):
                        Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
                            .frame(maxWidth: .infinity).padding(40)
                    case let .loaded(c):
                        messages(lane, texts: c.byEvent, shown: filter.indices(lane.events))
                    }
                } header: {
                    VStack(spacing: 0) {
                        header(lane).padding(.horizontal, 16).padding(.vertical, 10)
                        Divider()
                    }
                    .background(.bar)
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

    private func header(_ lane: AnatomyLane) -> some View {
        let spend = anatomy.spend.lane(lane.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Lane", selection: $laneID) {
                    ForEach(anatomy.lanesInTreeOrder) { l in
                        let cost = anatomy.spend.lane(l.id).map { " · \(Format.dollars($0.costMicros))" } ?? ""
                        Text(String(repeating: "  ", count: anatomy.depth(of: l)) + l.name + cost).tag(l.id)
                    }
                }
                .frame(maxWidth: 420)
                Toggle("Show tool output", isOn: $expandAll).toggleStyle(.checkbox)
                Spacer()
                if let spend {
                    Text("\(Format.dollars(spend.costMicros)) · \(spend.modelCalls) model calls · \(Format.tokens(spend.avgContext)) context on average")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            filterBar(lane)
            Text("Each model call reads the whole context again: its line shows what it read, what it wrote, and its cost. A tool result shows what it added to the context and its part of the next call. Thinking text is not saved in the transcript; its tokens are in the output.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func filterBar(_ lane: AnatomyLane) -> some View {
        HStack(spacing: 6) {
            Text("Show").font(.callout).foregroundStyle(.secondary)
            ForEach(ChatFilter.Kind.allCases) { k in
                Toggle(k.title, isOn: Binding(
                    get: { filter.kinds.contains(k) },
                    set: { on in if on { filter.kinds.insert(k) } else { filter.kinds.remove(k) } }
                ))
            }
            Divider().frame(height: 16)
            Toggle("Top 10% by cost", isOn: $filter.topCosts)
                .help("Only the most expensive 10% of the messages the other filters show (of all messages when none is on).")
            if filter.isOn {
                Button("Clear") { filter = ChatFilter() }.buttonStyle(.link)
                Text("\(filter.indices(lane.events).count) of \(lane.events.count) messages")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .toggleStyle(.button)
        .controlSize(.small)
    }

    @ViewBuilder
    private func messages(_ lane: AnatomyLane, texts: [Int: ChatText], shown: [Int]) -> some View {
        let maxCost = max(lane.maxAnswerCost, 1)
        if shown.isEmpty {
            Text("No messages match the filter.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
        }
        ForEach(shown, id: \.self) { i in
            let e = lane.events[i]
            Group {
                switch e.kind {
                case .prompt: promptView(lane, e, texts[i])
                case .answer: answerView(e, texts[i], maxCost: maxCost)
                case .tool: toolView(lane, i, e, texts[i])
                case .compact: marker(e.text ?? "Compacted", color: Palette.compact)
                case .error: marker(e.text ?? "API error", color: Palette.error)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func promptView(_ lane: AnatomyLane, _ e: AnatomyEvent, _ t: ChatText?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lane.id == "main" ? "You" : "Task from the lead").font(.caption.weight(.semibold))
                Text(e.start.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                cost(added: e.addedTokens, tokens: e.paidTokens, paid: e.costMicros)
            }
            Text(t?.text ?? e.text ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.prompt.opacity(0.12)))
    }

    private func answerView(_ e: AnatomyEvent, _ t: ChatText?, maxCost: UInt64) -> some View {
        let u = e.usage ?? TokenUsage()
        let read = u.inputTokens + u.cacheWriteTokens + u.cacheReadTokens
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Claude").font(.caption.weight(.semibold))
                Text([e.model ?? "", e.start.formatted(date: .omitted, time: .standard)].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if t?.thinking == true {
                    Label("thinking", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                        .help("This call had thinking blocks. Their text is not saved; their tokens are in the output.")
                }
                Spacer()
                Text("read \(Format.tokens(read)) · wrote \(Format.tokens(u.outputTokens))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("Read: cache read \(Format.tokens(u.cacheReadTokens)), cache write \(Format.tokens(u.cacheWriteTokens)), input \(Format.tokens(u.inputTokens)). Wrote: output tokens, with thinking.")
                ShareBar(share: Double(e.costMicros ?? 0) / Double(maxCost), color: Palette.answer)
                    .help("Compared with this lane's most expensive call.")
                Text(Format.dollars(e.costMicros ?? 0)).font(.caption.weight(.semibold)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            if let text = t?.text, !text.isEmpty {
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func toolView(_ lane: AnatomyLane, _ i: Int, _ e: AnatomyEvent, _ t: ChatText?) -> some View {
        let isOpen = expandAll || openTools.contains(i)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption2).rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 2).fill(Palette.tool(e.tool)).frame(width: 8, height: 8)
                Text(e.label).font(.caption.weight(.semibold))
                Text(e.command ?? e.text ?? "").font(.caption.monospaced()).lineLimit(1)
                    .foregroundStyle(e.isError ? .red : .secondary)
                Spacer(minLength: 8)
                if let b = e.resultBytes { Text(Format.bytes(b)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                cost(added: e.addedTokens, tokens: e.paidTokens, paid: e.costMicros)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if openTools.contains(i) { openTools.remove(i) } else { openTools.insert(i) }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if let input = t?.input {
                        ForEach(input.fields, id: \.name) { f in
                            snippet(f.name, f.text)
                        }
                    }
                    if let out = t?.output {
                        snippet(e.isError ? "error" : "output", out + (t?.outputTruncated == true ? "\n…" : ""))
                    }
                    HStack {
                        Button("Open the whole call") { shownCall = CallRef(lane: lane.id, index: i) }
                        if let agent = e.agentId, anatomy.lane(agent) != nil {
                            Button("Open this subagent's chat") { laneID = agent }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
    }

    private func snippet(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.count > 4_000 ? String(text.prefix(4_000)) + "\n…" : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.07)))
        }
    }

    /// What a prompt or tool result added to the context, and its part of the next call.
    private func cost(added: UInt64?, tokens: UInt64?, paid: UInt64?) -> some View {
        HStack(spacing: 8) {
            if let added, added > 0 {
                Text("+\(Format.tokens(added)) to context").help("Tokens this added to the context (estimated). Every later call of this lane reads them again.")
            }
            if let tokens, tokens > 0 {
                Text("\(Format.tokens(tokens)) tokens")
                    .help("Its part of the tokens of the model call after it: cache read, cache write, input and output. When several results came back before one call, the call is split evenly between them.")
            }
            if let paid {
                Text(Format.dollars(paid)).fontWeight(.medium).help("Its part of the cost of the model call after it.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func marker(_ text: String, color: Color) -> some View {
        HStack {
            Rectangle().fill(color).frame(height: 1)
            Text(text).font(.caption).foregroundStyle(color).fixedSize()
            Rectangle().fill(color).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}
