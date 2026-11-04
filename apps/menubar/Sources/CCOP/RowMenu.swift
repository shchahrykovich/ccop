import AppKit
import CCOPKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// The width of a text in a font, for table columns that must line up across
/// rows built as separate views.
func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
}

extension View {
    /// The right-click menu of a table row. A nil action shows as disabled.
    func rowMenu(view: (() -> Void)?, goTo: (() -> Void)?, fileName: String,
                 json: @escaping @MainActor () async throws -> Data) -> some View {
        contextMenu {
            Button("View") { view?() }.disabled(view == nil)
            Button("Go to Chat") { goTo?() }.disabled(goTo == nil)
            Divider()
            Button("Copy as JSON") { Task { await RowJSON.copy(json) } }
            Button("Export as JSON…") { Task { await RowJSON.save(fileName, json) } }
        }
    }
}

extension View {
    /// A row that a click acts on: it lights up under the pointer.
    func clickableRow(action: @escaping () -> Void) -> some View {
        modifier(ClickableRow(action: action))
    }
}

private struct ClickableRow: ViewModifier {
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.text.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6).inset(by: -4))
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // A click can change the tab, which takes the row away under the pointer.
            .onDisappear {
                if hovering { NSCursor.pop() }
                hovering = false
            }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

@MainActor
private enum RowJSON {
    static func copy(_ json: () async throws -> Data) async {
        do {
            let text = String(decoding: try await json(), as: UTF8.self)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func save(_ fileName: String, _ json: () async throws -> Data) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await json().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Over a chart's plot: tells a `ChartPick` what is under the pointer, and
/// what a click or a drag chooses.
struct ChartPicker: View {
    let proxy: ChartProxy
    @Binding var pick: ChartPick
    /// The value at an x position in the plot.
    let value: @MainActor (CGFloat) -> Int?

    var body: some View {
        GeometryReader { geo in
            let left = proxy.plotFrame.map { geo[$0].minX } ?? 0
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p): pick.hover(value(p.x - left))
                    case .ended: pick.hover(nil)
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in if let v = value(g.location.x - left) { pick.drag(to: v) } }
                    .onEnded { _ in pick.release() })
        }
    }
}
