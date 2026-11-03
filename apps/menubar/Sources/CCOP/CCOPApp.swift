import AppKit
import CCOPKit

/// An AppKit entry point, not a SwiftUI App: the app has no windows of its
/// own, only the menu bar icon and its popover (StatusItemController).
@main
enum CCOPApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon, as LSUIElement does for the bundle; also for `swift run`.
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { app.mainMenu = MainMenu.make(appName: "ccop") }
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(model: model)
        statusItem = controller
        model.start()
        // For development: `CCOP --show` opens the popover at launch.
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.showPopover() }
        }
        // For development: `CCOP --plan` opens the plan settings at launch.
        if CommandLine.arguments.contains("--plan") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.openPlanSettings?() }
        }
        // For development: `CCOP --window [<session id> [overview|anatomy|context]]`.
        if let i = CommandLine.arguments.firstIndex(of: "--window") {
            let rest = CommandLine.arguments.dropFirst(i + 1)
            let session = rest.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
            let tab = rest.dropFirst().first.flatMap(DetailTab.init(rawValue:))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // A session id may be its first characters.
                let id = session.flatMap { s in self.model.sessions.first { $0.id.hasPrefix(s) }?.id }
                controller.openWindow(session: id, tab: tab)
            }
        }
    }
}
