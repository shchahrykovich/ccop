import AppKit
import XCTest
@testable import CCOPKit

@MainActor
final class MainMenuTests: XCTestCase {
    func item(_ menu: NSMenu, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        menu.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
    }

    func testCommandWClosesTheFrontWindow() {
        let close = item(MainMenu.make(appName: "ccop"), key: "w")
        XCTAssertEqual(close?.action, #selector(NSWindow.performClose(_:)))
        XCTAssertNil(close?.target, "nil target sends the action to the key window")
    }

    func testCommandMMinimizesAndCommandQQuits() {
        let menu = MainMenu.make(appName: "ccop")
        XCTAssertEqual(item(menu, key: "m")?.action, #selector(NSWindow.performMiniaturize(_:)))
        XCTAssertEqual(item(menu, key: "q")?.action, #selector(NSApplication.terminate(_:)))
    }

    func testTheAppMenuStartsWithAboutThatOpensOurPanel() {
        let about = MainMenu.make(appName: "ccop").items.first?.submenu?.items.first
        XCTAssertEqual(about?.title, "About ccop")
        XCTAssertEqual(about?.action, #selector(AboutPanel.show(_:)))
        XCTAssertTrue(about?.target === AboutPanel.shared)
    }

    func testTheAboutPanelHasTheVersionAndALinkToTheRepository() throws {
        let options = AboutPanel.options(version: "1.2.3")
        XCTAssertEqual(options[.applicationVersion] as? String, "1.2.3")
        XCTAssertEqual(options[.version] as? String, "", "no build number in brackets")
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertEqual(credits.string, "github.com/shchahrykovich/ccop")
        XCTAssertEqual(credits.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://github.com/shchahrykovich/ccop"))
    }

    func testCopyAndSelectAllWorkInSelectableText() {
        let menu = MainMenu.make(appName: "ccop")
        XCTAssertEqual(item(menu, key: "c")?.action, #selector(NSText.copy(_:)))
        XCTAssertEqual(item(menu, key: "a")?.action, #selector(NSText.selectAll(_:)))
    }

    func testAWindowIsRaisedOverOtherAppsNotOnlyInItsOwnApp() {
        _ = NSApplication.shared
        let window = SpyWindow()
        window.raiseOverOtherApps()
        XCTAssertEqual([window.raised, window.madeKey], [1, 1])
        XCTAssertEqual(window.orderedInItsApp, 0, "makeKeyAndOrderFront leaves it behind the front app")
    }

    /// `activate()` is only a request: an app in the background may not get
    /// to the front, and then its new window stays behind the front app's.
    func testTheAboutPanelIsRaisedOverOtherAppsAtEachCall() {
        _ = NSApplication.shared
        let main = SpyWindow()
        let about = SpyWindow()
        var windows: [NSWindow] = [main]
        let panel = AboutPanel()

        panel.present(windows: { windows }, open: { windows.append(about) })
        XCTAssertEqual([about.raised, about.madeKey], [1, 1], "the first click")
        XCTAssertEqual([main.raised, main.madeKey], [0, 0], "another window of the app stays where it is")

        // Closed and opened again: the standard call reuses the same panel.
        panel.present(windows: { windows }, open: {})
        XCTAssertEqual(about.raised, 2, "the second click")
        XCTAssertEqual(main.raised, 0)
    }
}

/// Records what the panel asks of a window, and does not touch the screen.
private final class SpyWindow: NSWindow {
    var raised = 0
    var madeKey = 0
    override func orderFrontRegardless() { raised += 1 }
    override func makeKey() { madeKey += 1 }
    var orderedInItsApp = 0
    override func makeKeyAndOrderFront(_ sender: Any?) { orderedInItsApp += 1 }
}
