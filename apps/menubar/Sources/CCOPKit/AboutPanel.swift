import AppKit

/// The About panel: the standard one, which shows the icon and the bundle's
/// name, with the version and a link to the repository.
public extension NSWindow {
    /// `NSApp.activate()` is only a request. An app in the background may not
    /// get to the front, and `makeKeyAndOrderFront` then leaves the window
    /// behind the front app's: it looks as if nothing opened. Call this, then
    /// `activate()`.
    func raiseOverOtherApps() {
        orderFrontRegardless()
        makeKey()
    }
}

@MainActor
public final class AboutPanel: NSObject {
    public static let shared = AboutPanel()

    public static let repoURL = URL(string: "https://github.com/\(Updater.repo)")!

    private weak var panel: NSWindow?

    /// An empty `.version` removes the build number in brackets: here it is
    /// the same as the version.
    static func options(version: String) -> [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationVersion: version, .version: "", .credits: credits]
    }

    private static var credits: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: "github.com/\(Updater.repo)", attributes: [
            .link: repoURL,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: style,
        ])
    }

    @objc public func show(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        NSApp.activate()
        present(windows: { NSApp.windows }, open: { NSApp.orderFrontStandardAboutPanel(options: Self.options(version: version)) })
    }

    /// The standard call does not give its window, and reuses it after the
    /// first time: so it is the window that was not there before the first call.
    func present(windows: () -> [NSWindow], open: () -> Void) {
        let before = windows()
        open()
        panel = windows().first { window in !before.contains { $0 === window } } ?? panel
        panel?.raiseOverOtherApps()
    }
}
