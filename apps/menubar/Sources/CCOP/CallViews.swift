import AppKit
import CCOPKit
import SwiftUI

/// A value read on demand from the CLI.
enum Loadable<T> {
    case loading
    case loaded(T)
    case failed(String)
}

/// Which tool call to show in `CallSheet`.
struct CallRef: Identifiable, Hashable {
    let lane: String
    let index: Int
    var id: String { "\(lane) \(index)" }
}

/// What one tool call cost: its output, what it added to the context, and
/// the model call it made run.
struct CallConsumption: View {
    let lane: AnatomyLane
    let index: Int

    var body: some View {
        let e = lane.events[index]
        let next = lane.nextAnswer(after: index).map { lane.events[$0] }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Output", e.resultBytes.map { Format.bytes($0) } ?? "no result yet")
            row("Added to the context", e.addedTokens.map { "\(Format.tokens($0)) tokens (estimated)" } ?? "–")
            if let next, let u = next.usage {
                row("The next model call", "read \(Format.tokens(u.inputTokens + u.cacheWriteTokens + u.cacheReadTokens)) tokens "
                    + "(cache read \(Format.tokens(u.cacheReadTokens)), cache write \(Format.tokens(u.cacheWriteTokens)), input \(Format.tokens(u.inputTokens))), "
                    + "wrote \(Format.tokens(u.outputTokens)), cost \(Format.dollars(next.costMicros ?? 0))")
            }
            row("Part of that call", e.costMicros.map { Format.dollars($0) } ?? "–", bold: true)
            if e.isError, let error = e.error { row("Error", error, color: .red) }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func row(_ name: String, _ value: String, bold: Bool = false, color: Color = .primary) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).fontWeight(bold ? .semibold : .regular).foregroundStyle(color).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One tool call in full: its consumption, its whole input and output.
struct CallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let lane: AnatomyLane
    let index: Int

    var body: some View {
        let e = lane.events[index]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.label).font(.title3.weight(.semibold))
                if let g = e.group { Text(g).font(.callout.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                Button("Go to Chat") {
                    dismiss()
                    model.openInChat(ChatPlace(lane: lane.id, event: index))
                }
                .help("Close this and show this call in the Chat tab")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(lane.name) · \(e.start.formatted(date: .omitted, time: .standard))" + (e.text.map { " · \($0)" } ?? ""))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            CallConsumption(lane: lane, index: index)
            Divider()
            CallInputOutput(sessionID: sessionID, toolUseID: e.toolUseId)
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 920, minHeight: 480, idealHeight: 720)
        .closesOnClickOutside { dismiss() }
    }
}

/// The whole input and output of one tool call, read with `ccop call`.
struct CallInputOutput: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let toolUseID: String?
    @State private var call: Loadable<ToolCall> = .loading

    /// More than this is slow in a SwiftUI Text; Copy copies all of it.
    static let shownChars = 60_000

    var body: some View {
        Group {
            switch call {
            case .loading:
                ProgressView("Reading the call…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(why):
                VStack(alignment: .leading) {
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                }
            case let .loaded(c):
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(c.input.fields, id: \.name) { f in
                            block("Input: \(f.name)", f.text)
                        }
                        block("Output (\(Format.bytes(c.outputBytes))\(c.isError ? ", error" : ""))", c.output ?? "(no result yet)",
                              note: c.outputTruncated ? "ccop keeps the first 200,000 characters of an output." : nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: toolUseID) {
            guard let id = toolUseID else { call = .failed("This call has no id in the transcript."); return }
            switch await model.call(sessionID, toolUseID: id) {
            case let .success(c): call = .loaded(c)
            case let .failure(err): call = .failed(err.localizedDescription)
            }
        }
    }

    private func block(_ title: String, _ text: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            let cut = text.count > Self.shownChars
            Text(cut ? String(text.prefix(Self.shownChars)) + "\n…" : text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
            if cut { Text("Shown: the first \(Self.shownChars) characters. Copy copies all of it.").font(.caption).foregroundStyle(.secondary) }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

extension View {
    /// In a sheet: a click on the window under the sheet closes it. A macOS
    /// sheet does not close by itself; the click would only beep.
    func closesOnClickOutside(_ close: @escaping () -> Void) -> some View {
        background(OutsideClickWatcher(close: close))
    }
}

private struct OutsideClickWatcher: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let v = WatcherView()
        v.close = close
        return v
    }

    func updateNSView(_ v: WatcherView, context: Context) {
        v.close = close
    }

    final class WatcherView: NSView {
        var close: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // Only a click on the window this sheet is attached to; other windows work as before.
                guard let self, let sheet = self.window, let parent = sheet.sheetParent, event.window === parent else { return event }
                self.close?()
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func removeFromSuperview() {
            stop()
            super.removeFromSuperview()
        }
    }
}
