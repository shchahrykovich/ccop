import Foundation
import XCTest
@testable import CCOPKit

/// api/sessions.example.json is what `ccop sessions --json` prints; the Rust
/// test libs/core/tests/api_example.rs checks the same file.
final class SessionContractTests: XCTestCase {
    static var example: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("api/sessions.example.json")
    }

    func testTheExampleDecodes() throws {
        let list = try Session.decodeList(Data(contentsOf: Self.example))
        XCTAssertEqual(list.count, 2)
        let s = list[0]
        XCTAssertEqual(s.title, "Cart checkout feature")
        XCTAssertEqual(s.projectName, "shop")
        XCTAssertEqual(s.models.map(\.model), ["claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(s.usage.total, 120 + 140_000 + 3_200_000 + 21000)
        XCTAssertEqual(s.subagentUsage.requests, 12)
        XCTAssertEqual(s.usage.cacheWrite1HTokens, 120_000)
        XCTAssertEqual(s.costMicros, 2_031_500)
        XCTAssertTrue(s.active)
        // Six digits of fractions, cut to milliseconds.
        XCTAssertEqual(s.modifiedAt.timeIntervalSince1970, parseDate("2026-11-02T22:19:40.500Z")!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(list[1].startedAt)
        XCTAssertEqual(list[1].continuedIn, "9a1b2c3d-4e5f-4a7b-8c9d-0e1f2a3b4c5d")
        XCTAssertEqual(list[1].lastActivity, list[1].modifiedAt)
    }

    func testDates() {
        XCTAssertNotNil(parseDate("2026-11-02T22:19:40Z"))
        XCTAssertNotNil(parseDate("2026-11-02T22:19:40.5Z"))
        XCTAssertNotNil(parseDate("2026-11-02T22:19:40.123456789Z"))
        XCTAssertNil(parseDate("yesterday"))
    }
}

func session(_ id: String, title: String = "t", project: String = "/p/shop", at: String, output: UInt64 = 10,
             read: UInt64 = 0, active: Bool = false) -> Session {
    let date = parseDate(at)!
    return Session(id: id, projectDir: project, title: title, firstPrompt: "prompt-\(id)", lastPrompt: nil, gitBranch: "main",
                   version: nil, startedAt: date, updatedAt: date, modifiedAt: date, active: active, prompts: 1, subagents: 0,
                   usage: TokenUsage(cacheReadTokens: read, outputTokens: output, requests: 1), subagentUsage: TokenUsage(),
                   costMicros: 0, models: [], transcript: "/x/\(id).jsonl", sizeBytes: 1, continuedIn: nil)
}

final class SessionListTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    let now = parseDate("2026-11-02T15:00:00Z")!

    func testASessionWithNoTokensShowsOnlyWhileActive() {
        // A `claude -p /usage` run leaves a session that never called the model.
        let list = [
            session("empty", title: "/usage", at: "2026-11-02T14:00:00Z", output: 0),
            session("starting", at: "2026-11-02T14:59:00Z", output: 0, active: true),
            session("work", at: "2026-11-02T13:00:00Z"),
        ]
        XCTAssertEqual(SessionList.filter(list, query: "", period: .all, now: now).map(\.id), ["starting", "work"])
    }

    var sessions: [Session] {
        [
            session("a", title: "Fix login bug", at: "2026-11-02T09:00:00Z", output: 100),
            session("b", title: "Write docs", project: "/p/blog", at: "2026-11-02T14:00:00Z", output: 5),
            session("c", title: "Old cart work", at: "2026-11-01T20:00:00Z", output: 1),
            session("d", title: "Ancient", at: "2026-09-01T20:00:00Z", output: 1000),
        ]
    }

    func testPeriodsAndOrder() {
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .today, now: now, calendar: utc).map(\.id), ["b", "a"])
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .week, now: now, calendar: utc).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .all, now: now, calendar: utc).map(\.id), ["b", "a", "c", "d"])
    }

    func testSearchNeedsEveryWordInAnyField() {
        XCTAssertEqual(SessionList.filter(sessions, query: "LOGIN fix", period: .all, now: now).map(\.id), ["a"])
        XCTAssertEqual(SessionList.filter(sessions, query: "blog", period: .all, now: now).map(\.id), ["b"])
        // Only the first prompt of "c" has "prompt-c".
        XCTAssertEqual(SessionList.filter(sessions, query: "prompt-c", period: .all, now: now).map(\.id), ["c"])
        XCTAssertEqual(SessionList.filter(sessions, query: "login docs", period: .all, now: now).map(\.id), [])
    }

    func testFolderFilterKeepsOnlyThatFolder() {
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .all, folder: "/p/blog", now: now).map(\.id), ["b"])
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .all, folder: "/p/shop", now: now).map(\.id), ["a", "c", "d"])
        // A trailing slash names the same folder.
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .all, folder: "/p/blog/", now: now).map(\.id), ["b"])
        XCTAssertEqual(SessionList.filter(sessions, query: "", period: .all, folder: nil, now: now).count, 4)
        // Folder, period and search all apply.
        XCTAssertEqual(SessionList.filter(sessions, query: "cart", period: .week, folder: "/p/shop", now: now, calendar: utc).map(\.id), ["c"])
    }

    func testFolderChoicesOfThePeriod() {
        let today = SessionList.folders(sessions, period: .today, now: now, calendar: utc)
        XCTAssertEqual(today, [FolderChoice(path: "/p/blog", label: "blog", sessions: 1),
                               FolderChoice(path: "/p/shop", label: "shop", sessions: 1)])
        XCTAssertEqual(SessionList.folders(sessions, period: .all, now: now).map(\.sessions), [1, 3])
    }

    func testTheSelectedFolderStaysAChoiceOutsideItsPeriod() {
        let list = SessionList.folders(sessions, period: .today, keeping: "/p/old", now: now, calendar: utc)
        XCTAssertEqual(list.map(\.path), ["/p/blog", "/p/old", "/p/shop"])
        XCTAssertEqual(list[1].sessions, 0)
    }

    func testFoldersWithTheSameNameShowTheirParent() {
        let list = [
            session("a", project: "/work/shop", at: "2026-11-02T09:00:00Z"),
            session("b", project: "/home/shop", at: "2026-11-02T09:00:00Z"),
            session("c", project: "/x/Blog", at: "2026-11-02T09:00:00Z"),
        ]
        XCTAssertEqual(SessionList.folders(list, period: .all, now: now).map(\.label), ["Blog", "home/shop", "work/shop"])
    }

    func testFolderSearchNeedsEveryWordInTheNameOrPath() {
        let choices = [
            FolderChoice(path: "/p/apps/shop-web-admin", label: "shop-web-admin", sessions: 65),
            FolderChoice(path: "/p/apps/shop-api", label: "shop-api", sessions: 6),
            FolderChoice(path: "/p/work/blog", label: "blog", sessions: 3),
        ]
        XCTAssertEqual(SessionList.matching(choices, search: "").map(\.label), ["shop-web-admin", "shop-api", "blog"])
        XCTAssertEqual(SessionList.matching(choices, search: "SHOP").map(\.label), ["shop-web-admin", "shop-api"])
        XCTAssertEqual(SessionList.matching(choices, search: "shop admin").map(\.label), ["shop-web-admin"])
        // The path counts too: "work" and "apps" are only in paths.
        XCTAssertEqual(SessionList.matching(choices, search: "work").map(\.label), ["blog"])
        XCTAssertEqual(SessionList.matching(choices, search: "apps").map(\.label), ["shop-web-admin", "shop-api"])
        XCTAssertEqual(SessionList.matching(choices, search: "zzz").map(\.label), [])
    }

    func testDaySectionsWithTheirTokens() {
        let list = SessionList.filter(sessions, query: "", period: .all, now: now, calendar: utc)
        let sections = SessionList.byDay(list, now: now, calendar: utc)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Tuesday 1 September"])
        XCTAssertEqual(sections[0].sessions.map(\.id), ["b", "a"])
        XCTAssertEqual(sections[0].usage.total, 105)
        XCTAssertEqual(SessionList.todayTotal(sessions, now: now, calendar: utc), 105)
    }
}

final class FormatTests: XCTestCase {
    func testTokensMatchTheRustRules() {
        XCTAssertEqual([812, 46355, 999_499, 999_600, 9_311_043, 9_960_000, 46_000_000, 1_234_000_000].map(Format.tokens),
                       ["812", "46K", "999K", "1.0M", "9.3M", "10M", "46M", "1.2B"])
        XCTAssertEqual(Format.percent(0.956), "96%")
    }

    func testDurations() {
        XCTAssertEqual([0.85, 12.4, 245, 4020].map(Format.duration), ["850 ms", "12 s", "4m 05s", "1h 07m"])
        XCTAssertEqual(Format.duration(-1), "0 ms")
    }

    func testAgo() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let now = parseDate("2026-11-02T15:00:00Z")!
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-30), now: now, calendar: c), "just now")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-300), now: now, calendar: c), "5 min ago")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-3 * 3600), now: now, calendar: c), "3 h ago")
    }
}

final class ResumeTests: XCTestCase {
    func testTheCommandQuotesTheFolder() {
        let s = session("1d33-ab", project: "/Users/me/My Projects/it's", at: "2026-11-02T15:00:00Z")
        XCTAssertEqual(Resume.command(s), #"cd '/Users/me/My Projects/it'\''s' && claude --resume 1d33-ab"#)
        let plain = session("x1", project: "/Users/me/ccop", at: "2026-11-02T15:00:00Z")
        XCTAssertEqual(Resume.command(plain), "cd /Users/me/ccop && claude --resume x1")
        XCTAssertEqual(Resume.script(plain), "#!/bin/sh\nexec \"${SHELL:-/bin/zsh}\" -l -i -c 'cd /Users/me/ccop && claude --resume x1'\n")
    }
}

final class SessionSourceTests: XCTestCase {
    func testCCOPCLIWinsAndAMissingFileIsSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("ccop")
        try "#!/bin/sh\necho '[]'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        XCTAssertEqual(CLISessionSource.locate(environment: ["CCOP_CLI": cli.path])?.path, cli.path)
        XCTAssertEqual(try CLISessionSource(cli: cli).load(), [])
    }

    func testAFailingCLIReportsItsMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("ccop")
        try "#!/bin/sh\necho 'ccop: cannot read' >&2\nexit 1\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        XCTAssertThrowsError(try CLISessionSource(cli: cli).load()) { error in
            XCTAssertEqual(error as? SessionSourceError, .failed(status: 1, message: "ccop: cannot read"))
        }
    }
}
