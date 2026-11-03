import XCTest
@testable import CCOPKit

final class TitleBarActionTests: XCTestCase {
    func testNoSettingZooms() {
        XCTAssertEqual(TitleBarAction.from(action: nil, miniaturize: false), .zoom)
    }

    func testTheSystemSettingsChoices() {
        XCTAssertEqual(TitleBarAction.from(action: "Maximize", miniaturize: false), .zoom)
        XCTAssertEqual(TitleBarAction.from(action: "Fill", miniaturize: false), .zoom)
        XCTAssertEqual(TitleBarAction.from(action: "Minimize", miniaturize: false), .minimize)
        XCTAssertEqual(TitleBarAction.from(action: "None", miniaturize: false), .nothing)
    }

    func testTheOldMinimizeSettingCountsOnlyWithoutTheNewOne() {
        XCTAssertEqual(TitleBarAction.from(action: nil, miniaturize: true), .minimize)
        XCTAssertEqual(TitleBarAction.from(action: "Maximize", miniaturize: true), .zoom)
    }
}
