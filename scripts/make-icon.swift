import AppKit

// make-icon.swift <out.png>: the 1024 px app icon.
let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let colors = [NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
              NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.55, alpha: 1)]
NSGradient(colors: colors)!.draw(in: path, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
