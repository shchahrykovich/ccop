import CCOPKit
import Foundation
import XCTest
@testable import CCOP

/// A source whose sessions and anatomy the test changes between reads.
private final class FakeSource: SessionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Session] = []
    private var current: Anatomy
    private var reads = 0
    /// Runs in the middle of a read of the anatomy.
    var duringRead: (() -> Void)?

    init(sessions: [Session], anatomy: Anatomy) {
        list = sessions
        current = anatomy
    }

    func set(sessions: [Session], anatomy: Anatomy? = nil) {
        lock.withLock {
            list = sessions
            if let anatomy { current = anatomy }
        }
    }

    var anatomyReads: Int { lock.withLock { reads } }

    func load() throws -> [Session] { lock.withLock { list } }

    func anatomy(_ sessionID: String) throws -> Anatomy {
        let hook = lock.withLock {
            reads += 1
            return duringRead
        }
        hook?()
        return lock.withLock { current }
    }

    func chat(_ sessionID: String, lane: String) throws -> LaneChat { throw SessionSourceError.cliNotFound }
    func call(_ sessionID: String, toolUseID: String) throws -> ToolCall { throw SessionSourceError.cliNotFound }
    func usage(days: Int) throws -> UsageReport { throw SessionSourceError.cliNotFound }
    func guide() throws -> String { "" }
}

/// While the user is on a tab of the window, new data of the session does not
/// change the tab: the window says that updates are available.
@MainActor
final class WindowUpdatesTests: XCTestCase {
    private static var api: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("api")
    }

    /// Before the first read of the anatomy, and after it.
    private let t1 = Date().addingTimeInterval(-1_000)
    private let t2 = Date().addingTimeInterval(1_000)
    private var first: Session!
    private var other: Session!
    private var oldAnatomy: Anatomy!
    private var newAnatomy: Anatomy!
    private var source: FakeSource!
    private var model: AppModel!

    override func setUp() async throws {
        let list = try Session.decodeList(Data(contentsOf: Self.api.appendingPathComponent("sessions.example.json")))
        first = list[0]
        first.modifiedAt = t1
        other = list[1]
        other.modifiedAt = t1
        oldAnatomy = try Anatomy.decode(Data(contentsOf: Self.api.appendingPathComponent("anatomy.example.json")))
        newAnatomy = oldAnatomy
        newAnatomy.sessionId = "newer"
        source = FakeSource(sessions: [first, other], anatomy: oldAnatomy)
        model = AppModel(source: source)
        await refresh()
    }

    private func refresh() async {
        model.refresh()
        await wait { !self.model.loading }
    }

    private func wait(_ condition: @escaping () -> Bool, line: UInt = #line) async {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "the condition stayed false", line: line)
    }

    private var shownAnatomy: Anatomy? {
        if case let .loaded(a, _) = model.windowAnatomy { return a }
        return nil
    }

    /// Opens `first` in the window and waits for its tab.
    private func open() async {
        model.windowSelectedID = first.id
        await wait { self.shownAnatomy != nil }
    }

    /// The session grows on disk, and the next refresh sees it.
    private func sessionGrows() async {
        var newer = first!
        newer.modifiedAt = t2
        newer.costMicros += 1
        source.set(sessions: [newer, other], anatomy: newAnatomy)
        await refresh()
    }

    func testTheCountIsTheNewModelCallsAndPrompts() async {
        await open()
        XCTAssertEqual(model.windowUpdateCount, 0)
        var newer = first!
        newer.modifiedAt = t2
        newer.usage.requests += 12
        newer.prompts += 1
        source.set(sessions: [newer, other])
        await refresh()
        XCTAssertEqual(model.windowUpdateCount, 13)
        model.showLatestInWindow()
        XCTAssertEqual(model.windowUpdateCount, 0, "the tab shows them now")
    }

    func testNewDataWithNoNewCallHasNoCountButIsStillReported() async {
        await open()
        // A tool result was written: the file changed, no new model call yet.
        await sessionGrows()
        XCTAssertTrue(model.windowHasUpdates)
        XCTAssertEqual(model.windowUpdateCount, 0)
    }

    func testClickingTheChosenSessionGoesToItsOverview() async {
        await open()
        model.windowTab = .chat
        model.chooseInWindow(first.id)
        XCTAssertEqual(model.windowTab, .overview)
        XCTAssertEqual(model.windowSelectedID, first.id)
    }

    func testClickingTheChosenSessionWorksWhenTheWindowWasOpenedWithAPrefix() async {
        // `--window <id-prefix>` gives only the start of the id.
        model.windowSelectedID = String(first.id.prefix(6))
        model.windowTab = .chat
        model.chooseInWindow(first.id)
        XCTAssertEqual(model.windowTab, .overview)
    }

    func testClickingAnotherSessionKeepsTheTab() async {
        await open()
        model.windowTab = .chat
        model.chooseInWindow(other.id)
        XCTAssertEqual(model.windowTab, .chat)
        XCTAssertEqual(model.windowSelectedID, other.id)
    }

    func testChoosingASessionShowsItWithNoUpdatesToReport() async {
        await open()
        XCTAssertEqual(model.windowShown?.id, first.id)
        XCTAssertEqual(shownAnatomy, oldAnatomy)
        XCTAssertFalse(model.windowHasUpdates)
    }

    func testNewDataDoesNotChangeTheTabAndIsReported() async {
        await open()
        await sessionGrows()
        XCTAssertEqual(model.windowShown?.modifiedAt, t1, "the tab keeps the session it showed")
        XCTAssertEqual(model.windowShown?.costMicros, first.costMicros)
        XCTAssertEqual(shownAnatomy, oldAnatomy)
        XCTAssertEqual(source.anatomyReads, 1, "the anatomy is not read again by itself")
        XCTAssertTrue(model.windowHasUpdates)
        XCTAssertEqual(model.windowSelected?.modifiedAt, t2, "the list has the new data")
    }

    func testTheUpdateActionShowsTheNewDataAndKeepsTheOldDataWhileItLoads() async {
        await open()
        await sessionGrows()
        model.showLatestInWindow()
        // Read at once, before the load ended: the tab is not replaced by a spinner.
        XCTAssertEqual(shownAnatomy, oldAnatomy)
        XCTAssertTrue(model.windowUpdating)
        XCTAssertFalse(model.windowHasUpdates)
        await wait { self.shownAnatomy == self.newAnatomy }
        XCTAssertFalse(model.windowUpdating)
        XCTAssertEqual(model.windowShown?.modifiedAt, t2)
        XCTAssertFalse(model.windowHasUpdates)
    }

    func testAChangeDuringARead() async {
        var newer = first!
        source.duringRead = { [source] in
            // The file changes after the read started.
            Thread.sleep(forTimeInterval: 0.01)
            newer.modifiedAt = Date()
            source?.set(sessions: [newer])
            Thread.sleep(forTimeInterval: 0.01)
        }
        await open()
        source.duringRead = nil
        await refresh()
        XCTAssertTrue(model.windowHasUpdates)
        // The click must read again: the first read may have missed the change.
        model.showLatestInWindow()
        XCTAssertTrue(model.windowUpdating)
        await wait { !self.model.windowUpdating }
        XCTAssertEqual(source.anatomyReads, 2)
    }

    func testALoadForThePopoverDoesNotChangeTheTab() async {
        await open()
        await sessionGrows()
        // The popover shows the same session with the new data.
        model.loadAnatomy(model.windowSelected!)
        if case .loading? = model.anatomies[first.id] {} else { XCTFail("the popover's load should have started") }
        XCTAssertEqual(shownAnatomy, oldAnatomy)
        await wait { if case .loaded? = self.model.anatomies[self.first.id] { true } else { false } }
        XCTAssertEqual(shownAnatomy, oldAnatomy)
        XCTAssertTrue(model.windowHasUpdates)
    }

    func testGoingToAnotherTabShowsTheNewData() async {
        await open()
        await sessionGrows()
        model.windowTab = model.windowTab == .chat ? .spend : .chat
        await wait { self.shownAnatomy == self.newAnatomy }
        XCTAssertEqual(model.windowShown?.modifiedAt, t2)
        XCTAssertFalse(model.windowHasUpdates)
    }

    func testChoosingAnotherSessionDoesNotShowTheOldSessionsAnatomy() async {
        await open()
        model.windowSelectedID = other.id
        XCTAssertEqual(model.windowShown?.id, other.id)
        XCTAssertNil(shownAnatomy, "the old session's data must not stay on screen")
        await wait { self.shownAnatomy != nil }
    }

    func testASessionThatIsGoneIsNoLongerShown() async {
        await open()
        source.set(sessions: [other])
        await refresh()
        XCTAssertNil(model.windowShown)
        XCTAssertFalse(model.windowHasUpdates)
    }

    func testASessionChosenBeforeTheListLoadedIsShownAfterIt() async {
        let empty = AppModel(source: source)
        empty.windowSelectedID = first.id
        XCTAssertNil(empty.windowShown)
        empty.refresh()
        await wait { empty.windowShown?.id == self.first.id }
    }
}
