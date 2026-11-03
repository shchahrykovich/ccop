import XCTest
@testable import CCOPKit

/// A folder and its subfolders (worktrees): pick the folder alone, one
/// subfolder, or the folder with all its subfolders.
final class FolderTreeTests: XCTestCase {
    let now = parseDate("2026-11-02T15:00:00Z")!

    var sessions: [Session] {
        [
            session("a", project: "/p/book", at: "2026-11-02T09:00:00Z"),
            session("b", project: "/p/book/", at: "2026-11-02T10:00:00Z"),
            session("c", project: "/p/book/.claude/worktrees/wool", at: "2026-11-02T11:00:00Z"),
            session("d", project: "/p/book/docs/deep", at: "2026-11-02T12:00:00Z"),
            // A sibling whose name starts like the folder is not inside it.
            session("e", project: "/p/bookshop", at: "2026-11-02T13:00:00Z"),
        ]
    }

    func testOnlyTheFolderOrTheFolderWithItsSubfolders() {
        let only = SessionList.filter(sessions, query: "", period: .all, folder: .only("/p/book"), now: now)
        XCTAssertEqual(only.map(\.id), ["b", "a"])
        let tree = SessionList.filter(sessions, query: "", period: .all, folder: .withSubfolders("/p/book"), now: now)
        XCTAssertEqual(tree.map(\.id), ["d", "c", "b", "a"])
        let sub = SessionList.filter(sessions, query: "", period: .all, folder: .only("/p/book/.claude/worktrees/wool"), now: now)
        XCTAssertEqual(sub.map(\.id), ["c"])
    }

    func testSubfoldersGoUnderTheirParentWithTheirPathInsideIt() {
        let tree = SessionList.folderTree(SessionList.folders(sessions, period: .all, now: now))
        XCTAssertEqual(tree.map(\.folder.path), ["/p/book", "/p/bookshop"])
        let book = tree[0]
        XCTAssertEqual(book.folder.sessions, 2)
        XCTAssertEqual(book.total, 4)
        XCTAssertEqual(book.subfolders.map(\.path), ["/p/book/.claude/worktrees/wool", "/p/book/docs/deep"])
        XCTAssertEqual(book.subfolders.map { book.relativePath(of: $0) }, [".claude/worktrees/wool", "docs/deep"])
        XCTAssertTrue(tree[1].subfolders.isEmpty)
        XCTAssertEqual(tree[1].total, 1)
    }

    func testSearchKeepsAFolderWhenItOrASubfolderMatches() {
        let tree = SessionList.folderTree(SessionList.folders(sessions, period: .all, now: now))
        let wool = SessionList.matching(tree, search: "wool")
        XCTAssertEqual(wool.map(\.folder.path), ["/p/book"])
        XCTAssertEqual(wool[0].subfolders.map(\.path), ["/p/book/.claude/worktrees/wool"])
        // The parent matches: all its subfolders stay.
        XCTAssertEqual(SessionList.matching(tree, search: "book").map { $0.subfolders.count }, [2, 0])
        XCTAssertEqual(SessionList.matching(tree, search: "").count, 2)
        XCTAssertEqual(SessionList.matching(tree, search: "zzz").count, 0)
    }

    func testTheScopePath() {
        XCTAssertEqual(FolderScope.only("/p/a").path, "/p/a")
        XCTAssertEqual(FolderScope.withSubfolders("/p/a").path, "/p/a")
    }
}
