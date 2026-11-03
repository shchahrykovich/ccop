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

    func testTheAppMenuStartsWithAboutThatShowsTheVersion() {
        let about = MainMenu.make(appName: "ccop").items.first?.submenu?.items.first
        XCTAssertEqual(about?.title, "About ccop")
        XCTAssertEqual(about?.action, #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    }

    func testCopyAndSelectAllWorkInSelectableText() {
        let menu = MainMenu.make(appName: "ccop")
        XCTAssertEqual(item(menu, key: "c")?.action, #selector(NSText.copy(_:)))
        XCTAssertEqual(item(menu, key: "a")?.action, #selector(NSText.selectAll(_:)))
    }
}
