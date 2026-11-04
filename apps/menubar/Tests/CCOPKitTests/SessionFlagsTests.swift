import Foundation
import XCTest
@testable import CCOPKit

final class SessionFlagsTests: XCTestCase {
    let now = parseDate("2026-11-02T15:00:00Z")!
    let sessions = [
        session("a", project: "/p/shop", at: "2026-11-02T14:00:00Z"),
        session("b", project: "/p/blog", at: "2026-10-01T10:00:00Z"),
        session("c", title: "cart", project: "/p/shop", at: "2026-09-01T10:00:00Z"),
    ]

    func testTheFlaggedListShowsOnlyFlaggedSessionsOfAnyAgeNewestFirst() {
        let list = SessionList.filter(sessions, query: "", period: .flagged, flagged: ["c", "a"], now: now)
        XCTAssertEqual(list.map(\.id), ["a", "c"])
    }

    func testTheFlaggedListIsEmptyWithNoFlags() {
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .flagged, now: now), [])
    }

    func testAFlagFromASessionThatIsGoneShowsNothing() {
        let list = SessionList.filter(sessions, query: "", period: .flagged, flagged: ["gone", "b"], now: now)
        XCTAssertEqual(list.map(\.id), ["b"])
    }

    func testOtherPeriodsIgnoreFlags() {
        let list = SessionList.filter(sessions, query: "", period: .all, flagged: ["a"], now: now)
        XCTAssertEqual(list.map(\.id), ["a", "b", "c"])
    }

    func testSearchAndFolderApplyInTheFlaggedList() {
        let flagged: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(SessionList.filter(sessions, query: "cart", period: .flagged, flagged: flagged, now: now).map(\.id), ["c"])
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .flagged, folder: .only("/p/blog"), flagged: flagged, now: now).map(\.id), ["b"])
    }

    /// Other lists hide a closed session with no tokens. A person flagged this
    /// one, so it must not leave the list when it stops being active.
    func testAFlaggedSessionWithNoTokensStaysInTheFlaggedList() {
        let empty = session("e", at: "2026-11-02T14:00:00Z", output: 0)
        XCTAssertEqual(SessionList.filter([empty], query: "", period: .all, flagged: ["e"], now: now), [])
        XCTAssertEqual(SessionList.filter([empty], query: "", period: .flagged, flagged: ["e"], now: now).map(\.id), ["e"])
    }

    func testTheFolderMenuOfTheFlaggedListHasOnlyFoldersWithFlaggedSessions() {
        let choices = SessionList.folders(sessions, period: .flagged, flagged: ["b"], now: now)
        XCTAssertEqual(choices.map(\.path), ["/p/blog"])
        XCTAssertEqual(choices.map(\.sessions), [1])
    }

    func testFlagsAreSavedAndLoaded() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ccop-tests-\(UUID().uuidString)"))
        XCTAssertEqual(SessionFlags.load(defaults), [])
        SessionFlags.save(["a", "b"], defaults)
        XCTAssertEqual(SessionFlags.load(defaults), ["a", "b"])
        SessionFlags.save([], defaults)
        XCTAssertEqual(SessionFlags.load(defaults), [])
    }

    func testTheFlaggedPeriodHasATitleAndNoStart() {
        XCTAssertEqual(Period.flagged.title, "Flagged")
        XCTAssertNil(Period.flagged.start(now: now))
    }
}
