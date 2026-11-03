import AppKit

/// The app's main menu. macOS looks up key equivalents (Cmd+W, Cmd+C, ...) in
/// `NSApp.mainMenu`, so without it these keys do nothing in our windows. The
/// menu bar shows it only while the main window gives the app a Dock icon.
@MainActor
public enum MainMenu {
    public static func make(appName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appName, [
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        main.addItem(window)
        NSApp?.windowsMenu = window.submenu
        return main
    }

    /// Target nil: the action goes to the first responder, so Close acts on the key window.
    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = menu
        return top
    }
}
