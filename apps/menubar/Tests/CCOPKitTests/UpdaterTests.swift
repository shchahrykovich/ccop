import Foundation
import XCTest
@testable import CCOPKit

final class UpdaterTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(Updater.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(Updater.isNewer("v1.0.0", than: "0.9.99"))
        XCTAssertTrue(Updater.isNewer("0.2", than: "0.1.9"))
        XCTAssertFalse(Updater.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewer("0.1.0-beta", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewer("0.0.9", than: "0.1.0"))
    }

    func testOnlyGitHubHttpsIsTrusted() {
        XCTAssertTrue(Updater.isTrusted(URL(string: "https://github.com/shchahrykovich/ccop/releases/download/v0.2.0/ccop-0.2.0.dmg")!))
        XCTAssertTrue(Updater.isTrusted(URL(string: "https://objects.githubusercontent.com/x")!))
        XCTAssertTrue(Updater.isTrusted(URL(string: "https://release-assets.githubusercontent.com/x")!))
        XCTAssertFalse(Updater.isTrusted(URL(string: "http://github.com/x.dmg")!))
        XCTAssertFalse(Updater.isTrusted(URL(string: "https://github.com.evil.example/x.dmg")!))
        XCTAssertFalse(Updater.isTrusted(URL(string: "https://user@github.com/x.dmg")!))
        XCTAssertFalse(Updater.isTrusted(URL(string: "https://github.com:8443/x.dmg")!))
    }

    func testParseLatestRelease() throws {
        let json = """
        {"tag_name":"v0.2.0","body":"Fixes","assets":[
          {"name":"notes.txt","browser_download_url":"https://github.com/a/b/notes.txt"},
          {"name":"ccop-0.2.0.dmg","browser_download_url":"https://github.com/shchahrykovich/ccop/releases/download/v0.2.0/ccop-0.2.0.dmg"}]}
        """
        let r = try Updater.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.tag, "v0.2.0")
        XCTAssertEqual(r.notes, "Fixes")
        XCTAssertEqual(r.dmg.lastPathComponent, "ccop-0.2.0.dmg")
    }

    func testReleaseWithoutDmgOrWithForeignUrlIsRefused() {
        let noDmg = #"{"tag_name":"v1","assets":[]}"#
        XCTAssertThrowsError(try Updater.parse(Data(noDmg.utf8))) { XCTAssertEqual($0 as? Updater.Failure, .noDmg) }
        let foreign = #"{"tag_name":"v1","assets":[{"name":"a.dmg","browser_download_url":"https://evil.example/a.dmg"}]}"#
        XCTAssertThrowsError(try Updater.parse(Data(foreign.utf8))) {
            XCTAssertEqual($0 as? Updater.Failure, .untrustedURL("https://evil.example/a.dmg"))
        }
        XCTAssertThrowsError(try Updater.parse(Data("rate limited".utf8))) {
            XCTAssertEqual($0 as? Updater.Failure, .badResponse("rate limited"))
        }
    }

    func testLocalBuildsDoNotUpdateThemselves() {
        XCTAssertNotNil(Updater.disabledReason(teamID: nil), "ad-hoc or unsigned")
        XCTAssertNotNil(Updater.disabledReason(teamID: ""))
        XCTAssertNil(Updater.disabledReason(teamID: "ABCDE12345"), "Developer ID release")
    }

    func testABuildWithoutATeamIDIsALocalBuild() {
        XCTAssertTrue(Updater.isLocalBuild(teamID: nil), "ad-hoc or unsigned")
        XCTAssertTrue(Updater.isLocalBuild(teamID: ""))
        XCTAssertFalse(Updater.isLocalBuild(teamID: "ABCDE12345"), "Developer ID release")
    }

    func testOnlyACopyInAnApplicationsFolderIsReplaced() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertNotNil(Updater.obstacle(appURL: URL(fileURLWithPath: "/tmp/build/CCOP"), home: home))
        XCTAssertNotNil(Updater.obstacle(appURL: URL(fileURLWithPath: "/Users/someone/Downloads/CCOP.app"), home: home))
        XCTAssertNotNil(Updater.obstacle(appURL: URL(fileURLWithPath: "/Volumes/ccop 0.2.0/CCOP.app"), home: home))
    }

    func testInstallScriptQuotesPathsAndChecksTheTeam() {
        let script = Updater.installScript(
            dmg: URL(fileURLWithPath: "/tmp/it's here/ccop-0.2.0.dmg"),
            dest: URL(fileURLWithPath: "/Applications/CCOP.app"),
            pid: 4242, team: "ABCDE12345", log: URL(fileURLWithPath: "/tmp/update.log"))
        XCTAssertTrue(script.contains("DMG='/tmp/it'\\''s here/ccop-0.2.0.dmg'"), script)
        XCTAssertTrue(script.contains("DEST='/Applications/CCOP.app'"))
        XCTAssertTrue(script.contains("PID=4242"))
        XCTAssertTrue(script.contains("TEAM='ABCDE12345'"))
        XCTAssertTrue(script.contains("SRC=\"$MOUNT/CCOP.app\""))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict \"$SRC\""))
        XCTAssertTrue(script.contains("[ \"$NEW_TEAM\" = \"$TEAM\" ]"))
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine"))
    }

    func testInstallScriptIsValidBash() throws {
        let script = Updater.installScript(dmg: URL(fileURLWithPath: "/tmp/a.dmg"), dest: URL(fileURLWithPath: "/Applications/CCOP.app"),
                                           pid: 1, team: "ABCDE12345", log: URL(fileURLWithPath: "/tmp/u.log"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ccop-script-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", file.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    /// An unsigned test binary has no Team ID, the same as an ad-hoc build.
    func testAnUnsignedFileHasNoTeam() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ccop-unsigned-\(UUID().uuidString)")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(Updater.teamIdentifier(of: file))
    }
}
