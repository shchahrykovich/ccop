import Foundation
import XCTest
@testable import CCOPKit

final class CLIInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// A folder that looks like an app bundle with its CLI.
    private func bundle(_ name: String) throws -> URL {
        let tool = root.appendingPathComponent("\(name).app").appendingPathComponent(CLIInstaller.toolPath)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private var bin: URL { root.appendingPathComponent("made/up/bin") }

    private func destination(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    func testItMakesTheFolderAndTheLinkAndCanRunAgain() throws {
        let tool = try bundle("CCOP")
        let installer = CLIInstaller(tool: tool, binDir: bin)
        let link = try installer.install()
        XCTAssertEqual(link.lastPathComponent, "ccop")
        XCTAssertEqual(try destination(link), tool.path)
        XCTAssertEqual(try installer.install(), link)
        XCTAssertEqual(try destination(link), tool.path)
    }

    func testALinkToAnotherCCOPBundleIsReplaced() throws {
        let installer = CLIInstaller(tool: try bundle("CCOP"), binDir: bin)
        let link = try installer.install()
        let dev = try bundle("CCOP Dev")
        XCTAssertEqual(try CLIInstaller(tool: dev, binDir: bin).install(), link)
        XCTAssertEqual(try destination(link), dev.path)
    }

    func testAForeignFileOrLinkIsLeftAlone() throws {
        let tool = try bundle("CCOP")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("ccop")
        try "mine".write(to: link, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CLIInstaller(tool: tool, binDir: bin).install()) { error in
            XCTAssertEqual(error as? CLIInstaller.Failure, .occupied(link))
        }
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "mine")

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/made/up/other-tool")
        XCTAssertThrowsError(try CLIInstaller(tool: tool, binDir: bin).install())
        XCTAssertEqual(try destination(link), "/made/up/other-tool")
    }

    func testAMissingToolIsReported() {
        let tool = root.appendingPathComponent("Nothing.app").appendingPathComponent(CLIInstaller.toolPath)
        XCTAssertThrowsError(try CLIInstaller(tool: tool, binDir: bin).install()) { error in
            XCTAssertEqual(error as? CLIInstaller.Failure, .toolMissing(tool))
        }
    }

    func testThePathCheckFindsTheFolderAmongOthers() {
        let installer = CLIInstaller(tool: root, binDir: URL(fileURLWithPath: "/made/up/.local/bin"))
        XCTAssertTrue(installer.isOnPath("/usr/bin:/made/up/.local/bin:/bin"))
        XCTAssertTrue(installer.isOnPath("/made/up/.local/bin/"))
        XCTAssertFalse(installer.isOnPath("/usr/bin:/made/up/.local"))
        XCTAssertFalse(installer.isOnPath(""))
    }

    func testThePathIsReadFromWhatAShellPrints() {
        XCTAssertEqual(CLIInstaller.path(inShellOutput: "Welcome!\nCCOP_PATH=/usr/bin:/bin\n"), "/usr/bin:/bin")
        XCTAssertNil(CLIInstaller.path(inShellOutput: "nothing here\n"))
        XCTAssertEqual(CLIInstaller.path(inShellOutput: "CCOP_PATH=/old\nCCOP_PATH=/new"), "/new", "the last one is ours")
    }
}

final class AgentPromptTests: XCTestCase {
    private func session() throws -> Session {
        let json = """
        {"id":"abc-123","project_dir":"/made/up/shop","title":"Cart fix","first_prompt":null,"last_prompt":null,"git_branch":null,"version":null,
         "started_at":null,"updated_at":null,"modified_at":"2026-11-02T10:00:00Z","active":false,"prompts":1,"subagents":0,
         "usage":{"input_tokens":0,"cache_write_tokens":0,"cache_write_1h_tokens":0,"cache_read_tokens":0,"output_tokens":0,"requests":0},
         "subagent_usage":{"input_tokens":0,"cache_write_tokens":0,"cache_write_1h_tokens":0,"cache_read_tokens":0,"output_tokens":0,"requests":0},
         "cost_micros":0,"models":[],"transcript":"/made/up/abc-123.jsonl","size_bytes":0,"continued_in":null}
        """
        return try Session.decodeList(Data("[\(json)]".utf8))[0]
    }

    func testItHasTheGuideAndTheSessionToLookAt() throws {
        let text = AgentPrompt.text(guide: "# The guide\n\nRead this.\n", session: try session(), cli: nil)
        XCTAssertTrue(text.hasPrefix("# The guide\n\nRead this.\n\n## This session\n"), text)
        XCTAssertTrue(text.contains("`abc-123`"), text)
        XCTAssertTrue(text.contains("Cart fix"), text)
        XCTAssertTrue(text.contains("/made/up/shop"), text)
        XCTAssertTrue(text.contains("`ccop brief abc-123`"), text)
        XCTAssertFalse(text.contains("is not found"), text)
    }

    func testAPathWithASpaceIsQuotedSoItCanBePasted() throws {
        let text = AgentPrompt.text(guide: "G", session: try session(), cli: "/made/up/CCOP Dev.app/Contents/Helpers/ccop")
        XCTAssertTrue(text.contains("'/made/up/CCOP Dev.app/Contents/Helpers/ccop'"), text)
    }
}
