import AppKit

// make-icon.swift <out.png> [release|dev]: the 1024 px app icon.
// dev: a slate gradient with a yellow DEV band, so a local build is never
// taken for a release in the Dock, Finder or the About panel.
let size: CGFloat = 1024
let args = Array(CommandLine.arguments.dropFirst())
let out = args.first ?? "icon.png"
let dev = args.dropFirst().first == "dev"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let colors = dev
    ? [NSColor(calibratedRed: 0.39, green: 0.45, blue: 0.55, alpha: 1),
       NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.23, alpha: 1)]
    : [NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
       NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.55, alpha: 1)]
NSGradient(colors: colors)!.draw(in: path, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: dev ? 330 : 400, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let y = dev ? 560 - s.height / 2 : (size - s.height) / 2
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: y, width: s.width, height: s.height))
}
if dev {
    // The band: the lower part of the rounded square, clipped to it.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1).setFill()
    NSRect(x: 100, y: 100, width: 824, height: 250).fill()
    NSGraphicsContext.restoreGraphicsState()
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: 170, weight: .heavy),
        .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.23, alpha: 1),
        .kern: 12,
    ])
    let t = text.size()
    text.draw(at: NSPoint(x: (size - t.width) / 2 + 6, y: 100 + (250 - t.height) / 2))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
