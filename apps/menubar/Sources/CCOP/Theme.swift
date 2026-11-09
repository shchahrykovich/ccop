import AppKit
import CCOPKit
import SwiftUI

/// Colors and small parts shared by the popover and the window, with the
/// values of the design boards (StyleSheet, Main, PopoverDark). Colors have a
/// light and a dark value; they differ in lightness as well as hue, so a bar
/// still reads in grey.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: nsDynamic(light, dark))
    }

    /// The AppKit form of `dynamic`, for drawing in an image (the menu bar battery).
    static func nsDynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        }
    }

    /// Black in light mode and white in dark mode, at two opacities.
    static func ink(_ light: Double, _ dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        })
    }

    // Kinds of token.
    static let input = dynamic(0x2563EB, 0x5B8CFF)
    static let cacheWrite = dynamic(0xF59E0B, 0xF5A524)
    static let cacheRead = dynamic(0x93C5FD, 0xA9CBFF)
    static let output = dynamic(0x6D28D9, 0xA685F2)

    // Status.
    static let nsOk = nsDynamic(0x1E8E4E, 0x3CCB7F)
    static let nsWarn = nsDynamic(0xB26B00, 0xF2B13B)
    static let nsBad = nsDynamic(0xD23B2E, 0xFF6B5E)
    static let ok = Color(nsColor: nsOk)
    static let warn = Color(nsColor: nsWarn)
    static let bad = Color(nsColor: nsBad)

    /// The colour of the week, on the Week card and the battery's right half.
    static func nsWeek(_ tone: WeekTone) -> NSColor {
        switch tone {
        case .ok: nsOk
        case .warn: nsWarn
        case .bad: nsBad
        }
    }

    // Text and lines (--text, --text2, --text3, --line, --line2).
    static let text = dynamic(0x1D1D1F, 0xF2F2F4)
    static let text2 = dynamic(0x5F5F64, 0xB9B9BF)
    static let text3 = dynamic(0x6E6E73, 0xA1A1A8)
    static let line = ink(0.10, 0.12)
    static let line2 = ink(0.06, 0.07)
    static let accent = dynamic(0x2563EB, 0x4C8DFF)

    // Backgrounds.
    /// The popover (--pop).
    static let pop = dynamic(0xF7F7F8, 0x262628)
    /// Fields, cards in the popover, the list (--bg).
    static let bg = dynamic(0xFFFFFF, 0x1E1E20)
    /// Cards in the window (--soft).
    static let soft = dynamic(0xF7F7F8, 0x2C2C2E)
    /// The window's sidebar (--side).
    static let side = dynamic(0xEEEEF0, 0x29292B)
    /// A segmented control's groove (--ctl).
    static let ctl = ink(0.055, 0.08)

    // Tools, the same in Spend, Anatomy and Chat.
    static let bash = dynamic(0x0D9488, 0x2DD4BF)
    static let read = dynamic(0xCA8A04, 0xEAB308)
    static let edit = dynamic(0xDB2777, 0xF472B6)
    static let grep = dynamic(0x4F46E5, 0x818CF8)
    static let agent = dynamic(0x6D28D9, 0xA685F2)
    static let web = dynamic(0x0284C7, 0x38BDF8)
    static let otherTool = dynamic(0x6E6E73, 0xA1A1A8)
    static let modelCall = dynamic(0xC2C2C8, 0x5A5A60)
    static let prompt = ok

    /// A soft card background on the window or popover.
    static let card = soft
    /// The chosen segment of a segmented control (--ctlOn).
    static let segmentOn = dynamic(0xFFFFFF, 0x5A5A5F)
    /// The window's main area, right of the sidebar.
    static let page = bg
    static let cardStroke = line2
    /// The groove of a bar (--track).
    static let track = ink(0.08, 0.12)

    /// The color and SF Symbol of a tool by its name.
    static func tool(_ name: String) -> (color: Color, symbol: String) {
        switch name {
        case "Bash", "BashOutput", "KillShell": (bash, "terminal")
        case "Read", "NotebookRead": (read, "doc.text")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": (edit, "pencil")
        case "Grep", "Glob", "LS": (grep, "magnifyingglass")
        case "Agent", "Task": (agent, "point.3.connected.trianglepath.dotted")
        case "WebFetch", "WebSearch": (web, "globe")
        default: (otherTool, "wrench.and.screwdriver")
        }
    }

    /// Green under half of the allowance, then to red at the whole of it.
    static func allowance(_ fraction: Double) -> Color {
        Color(nsColor: nsAllowance(fraction))
    }

    /// The AppKit form of `allowance`: the Today card and the battery's left half.
    static func nsAllowance(_ fraction: Double) -> NSColor {
        NSColor(hue: Plan.hue(ofAllowance: fraction), saturation: 0.85, brightness: 0.78, alpha: 1)
    }

    /// `~/code/shop` for `/Users/me/code/shop`.
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// The design's sizes are in points: 13 body, 12 small, 11 caption.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The design's buttons: a filled accent button, or a white one with a thin
/// border.
struct DesignButtonStyle: ButtonStyle {
    enum Kind { case primary, bordered, plain }
    var kind: Kind = .bordered
    var height: CGFloat = 28
    var radius: CGFloat = 6
    var padding: CGFloat = 10
    var fontSize: CGFloat = 13
    var weight: Font.Weight = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(fontSize, kind == .primary ? .medium : weight))
            .foregroundStyle(kind == .primary ? Color.white : Theme.text)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(kind == .primary ? Theme.accent : (kind == .bordered ? Theme.bg : .clear),
                        in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                if kind == .bordered { RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// A label with an icon before the text, at the design's gap of 6.
struct IconLabel: View {
    let title: String
    let symbol: String
    var iconSize: CGFloat = 13

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: iconSize - 1))
            Text(title)
        }
    }
}

/// A rounded square with a tool's symbol, tinted with its color.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// A bar filled to `value` (0...1), with an optional mark at `mark`.
struct Meter: View {
    let value: Double
    let color: Color
    var height: CGFloat = 5
    /// Gaps across the bar, as parts of its width: the starts of days.
    var ticks: [Double] = []
    /// A part of the bar to show as today: a darker track and an outline
    /// that stays visible when the fill covers it.
    var today: ClosedRange<Double>?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if let today {
                    RoundedRectangle(cornerRadius: (height + 4) / 2)
                        .strokeBorder(Theme.text3, lineWidth: 1)
                        .frame(width: g.size.width * (today.upperBound - today.lowerBound) + 4, height: height + 4)
                        .offset(x: g.size.width * today.lowerBound - 2)
                }
                ZStack(alignment: .leading) {
                    Theme.track
                    if let today {
                        Theme.text3.opacity(0.45)
                            .frame(width: g.size.width * (today.upperBound - today.lowerBound))
                            .offset(x: g.size.width * today.lowerBound)
                    }
                }
                .frame(height: height)
                .clipShape(Capsule())
                Capsule().fill(color).frame(width: max(0, g.size.width * min(1, value)), height: height)
                ForEach(ticks, id: \.self) { t in
                    Rectangle().fill(Theme.bg).frame(width: 1.5, height: height)
                        .offset(x: g.size.width * t - 0.75)
                }
            }
            .frame(width: g.size.width, height: height)
        }
        .frame(height: height)
    }
}

/// A small label above a big number, on a card. `big` is the window's card
/// (soft grey, 24 pt); else the popover's (white, 17 pt).
struct StatCard: View {
    let label: String
    let value: String
    var detail: String?
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: big ? 3 : 2) {
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            Text(value).font(.ui(big ? 24 : 17, .semibold)).tracking(big ? -0.24 : 0).monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.ui(11)).foregroundStyle(Theme.text2).monospacedDigit().lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, big ? 14 : 10)
        .padding(.vertical, big ? 12 : 8)
        .background(big ? Theme.soft : Theme.bg, in: RoundedRectangle(cornerRadius: big ? 10 : 9))
        .overlay(RoundedRectangle(cornerRadius: big ? 10 : 9).strokeBorder(Theme.line2))
    }
}

/// A value with a Copy button that shows while the pointer is over it.
struct CopyableValue: View {
    @Environment(AppModel.self) private var model
    let text: String
    var monospaced = true
    var help = "Copy"
    var size: CGFloat = 11.5
    var rowHeight: CGFloat = 22
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(monospaced ? .mono(size) : .ui(size))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                model.copy(text)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                // Only the icon: no text, no border, no plate.
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Theme.ok : Theme.text2)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || copied ? 1 : 0)
            .help(help)
            .accessibilityLabel(help)
        }
        .frame(minHeight: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The hover plate reaches 4 pt left of the text without moving it.
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.ink(0.04, 0.06) : .clear).padding(.leading, -4)
        }
        .onHover { hovering = $0 }
    }
}

/// A segmented control drawn by hand: the system one shows its chosen
/// segment grey in a popover. Equal widths (the period), or each segment as
/// wide as its title (the window's tabs).
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var height: CGFloat = 22
    var equalWidths = true
    var radius: CGFloat = 7
    /// An SF Symbol before an option's title; nil: none.
    var symbol: (Value) -> String? = { _ in nil }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 5) {
                        if let name = symbol(option.value) {
                            Image(systemName: name)
                                .font(.ui(11, on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.text2)
                                .accessibilityHidden(true)
                        }
                        Text(option.title)
                    }
                    .font(.ui(12, on ? .medium : .regular))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, equalWidths ? 0 : 12)
                    .frame(maxWidth: equalWidths ? .infinity : nil)
                    .frame(height: height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: radius - 2).fill(Theme.segmentOn)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    }
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.ctl, in: RoundedRectangle(cornerRadius: radius))
    }
}

/// A square button with no border and an SF Symbol (the popover's header).
struct HeaderIconButton: View {
    let symbol: String
    let help: String
    var iconSize: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize))
                .foregroundStyle(Theme.text2)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small square button with a thin border and an SF Symbol.
struct SmallIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    var fill: Color = Theme.pop
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .frame(width: size, height: size)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An uppercase small heading.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.ui(11, .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.text3)
    }
}

/// A coloured dot; with `halo`, the green ring of an active session.
struct ActiveDot: View {
    var size: CGFloat = 7
    var color: Color = Theme.ok
    var halo = true

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(Circle().fill(halo ? Theme.ok.opacity(0.18) : .clear).frame(width: size + 6, height: size + 6))
    }
}

extension View {
    /// A part of the window drawn over the title bar. A double click on its
    /// empty space does what the title bar's would (zoom, minimize or
    /// nothing, as in System Settings); a drag moves the window.
    func titleBarArea() -> some View {
        background(TitleBarClicks())
    }
}

private struct TitleBarClicks: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClickView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class ClickView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch TitleBarAction.current {
            case .zoom: window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .nothing: break
            }
        }
    }
}

/// A tab's scroll view, as in other Mac apps: ⌘↓ and End go to the end,
/// ⌘↑ and Home to the start. The two ends are marked in overlays, so the
/// content's own layout (such as pinned headers) stays as it is.
struct PageScrollView<Content: View>: View {
    private let content: (ScrollViewProxy) -> Content

    private enum End: Hashable { case top, bottom }

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = { _ in content() }
    }

    /// For a page that scrolls to one of its rows.
    init(@ViewBuilder withProxy content: @escaping (ScrollViewProxy) -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content(proxy)
                    .overlay(alignment: .top) { Color.clear.frame(height: 1).id(End.top) }
                    .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id(End.bottom) }
            }
            .background {
                // Keys only: the buttons are not seen and take no clicks.
                ZStack {
                    Button("") { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(End.top, anchor: .top) } }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button("") { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(End.bottom, anchor: .bottom) } }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                    Button("") { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(End.top, anchor: .top) } }
                        .keyboardShortcut(.home, modifiers: [])
                    Button("") { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(End.bottom, anchor: .bottom) } }
                        .keyboardShortcut(.end, modifiers: [])
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}
