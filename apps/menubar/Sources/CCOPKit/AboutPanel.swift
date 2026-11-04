import AppKit

/// The About panel: the standard one, which shows the icon and the bundle's
/// name, with the version and a link to the repository.
@MainActor
public final class AboutPanel: NSObject {
    public static let shared = AboutPanel()

    public static let repoURL = URL(string: "https://github.com/\(Updater.repo)")!

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
        NSApp.orderFrontStandardAboutPanel(options: Self.options(version: version))
    }
}
