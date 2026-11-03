import AppKit
import CCOPKit
import SwiftUI

/// Colors and small parts shared by the popover and the window. Colors have a
/// light and a dark value; they differ in lightness as well as hue, so a bar
/// still reads in grey.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
    }

    // Kinds of token.
    static let input = dynamic(0x2563EB, 0x5B8CFF)
    static let cacheWrite = dynamic(0xF59E0B, 0xF5A524)
    static let cacheRead = dynamic(0x93C5FD, 0xA9CBFF)
    static let output = dynamic(0x6D28D9, 0xA685F2)

    // Status.
    static let ok = dynamic(0x1E8E4E, 0x3CCB7F)
    static let warn = dynamic(0xB26B00, 0xF2B13B)
    static let bad = dynamic(0xD23B2E, 0xFF6B5E)

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
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color.primary.opacity(0.07)
    static let track = Color.primary.opacity(0.08)

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
        Color(hue: Plan.hue(ofAllowance: fraction), saturation: 0.85, brightness: 0.78)
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
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
    var mark: Double?
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(0, g.size.width * min(1, value)))
                if let mark {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary)
                        .frame(width: 2, height: height + 6)
                        .offset(x: g.size.width * min(1, max(0, mark)) - 1)
                }
            }
        }
        .frame(height: height)
    }
}

/// A small label above a big number, on a card.
struct StatCard: View {
    let label: String
    let value: String
    var detail: String?
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: big ? 22 : 17, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardStroke))
    }
}

/// A value with a Copy button that shows while the pointer is over it.
struct CopyableValue: View {
    @Environment(AppModel.self) private var model
    let text: String
    var monospaced = true
    var help = "Copy"
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                model.copy(text)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .opacity(hovering || copied ? 1 : 0)
            .help(help)
            .accessibilityLabel(help)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
    }
}

/// An uppercase small heading.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
