import Foundation
import XCTest
@testable import CCOPKit

final class CauseCallsTests: XCTestCase {
    private func cause(_ kind: CauseKind, _ name: String) -> Cause {
        Cause(kind: kind, name: name, count: 0, errors: 0, modelCalls: 0, costMicros: 0, tokens: 0, errorCostMicros: 0, avgContext: 0, addedTokens: 0, items: [])
    }

    func testTitles() {
        XCTAssertEqual(cause(.tool, "Bash").title, "Bash results")
        XCTAssertEqual(cause(.other, "Other").title, "Start")
    }

    func testTheHelpOfACauseStartsWithItsFullName() {
        var c = cause(.tool, "mcp__wiki__get_page")
        c.costMicros = 430_000
        c.errorCostMicros = 10_000
        c.count = 3
        c.errors = 1
        c.modelCalls = 2
        let s = Spend(costMicros: 860_000, tokens: 0, causes: [c], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(s.help(c).components(separatedBy: "\n"), [
            "mcp__wiki__get_page results",
            "Model calls after these results. $0.01 of it came after failed calls.",
            "$0.43, 50% of the session.",
            "Count: 3, 1 failed",
            "Model calls: 2",
        ])
        XCTAssertEqual(s.help(cause(.prompt, "Your messages")).components(separatedBy: "\n").first, "Your messages")
    }

    func testTheHelpOfACauseHasItsDescriptionAfterTheName() {
        var c = cause(.tool, "mcp__notes__get_page")
        c.description = "Read a page by slug."
        let s = Spend(costMicros: 0, tokens: 0, causes: [c], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(Array(s.help(c).components(separatedBy: "\n").prefix(2)), ["mcp__notes__get_page results", "Read a page by slug."])
    }

    func testAToolNameSplitsIntoServerAndTool() {
        XCTAssertNil(ToolName("Bash").server)
        XCTAssertEqual(ToolName("Bash").short, "Bash")
        let plain = ToolName("mcp__notes__get_page")
        XCTAssertEqual(plain.server, "notes")
        XCTAssertEqual(plain.short, "get_page")
        XCTAssertEqual(ToolName("mcp__claude-in-chrome__browser_batch").server, "claude-in-chrome")
        XCTAssertEqual(ToolName("mcp__plugin_tools_box-maker__fold").server, "box-maker")
        XCTAssertEqual(ToolName("mcp__claude_ai_Note_Box__get_note").server, "Note Box")
        XCTAssertEqual(ToolName("mcp__notes__a__b").short, "a__b", "a tool's name may hold the separator")
        for odd in ["mcp__notes", "mcp____get", "mcp__notes__", "my__notes__get"] {
            XCTAssertNil(ToolName(odd).server, odd)
            XCTAssertEqual(ToolName(odd).short, odd)
        }
    }

    func testAToolsSymbolComesFromTheFirstWordOfItsNameWithOne() {
        XCTAssertEqual(ToolName("mcp__notes__search").symbol, "magnifyingglass")
        XCTAssertEqual(ToolName("mcp__notes__get_page").symbol, "arrow.down.doc")
        XCTAssertEqual(ToolName("mcp__notes__begin_file_upload").symbol, "arrow.up.doc")
        XCTAssertEqual(ToolName("mcp__notes__tabs_close").symbol, "macwindow")
        XCTAssertEqual(ToolName("mcp__notes__xyz").symbol, "wrench.and.screwdriver")
        XCTAssertEqual(ToolName("ToolSearch").symbol, "magnifyingglass")
        XCTAssertEqual(ToolName("mcp__notes__Skill").symbol, "wrench.and.screwdriver", "the built-in names are for built-in tools")
    }

    func testCauseGroupsHaveClaudeCodeFirstThenServersByCost() {
        func costing(_ kind: CauseKind, _ name: String, _ micros: UInt64) -> Cause {
            var c = cause(kind, name); c.costMicros = micros; return c
        }
        let s = Spend(costMicros: 0, tokens: 0, causes: [
            costing(.tool, "mcp__small__a", 5),
            costing(.tool, "mcp__big__a", 4),
            costing(.tool, "mcp__big__b", 3),
            costing(.tool, "Bash", 1),
            costing(.prompt, "Your prompts", 2),
            costing(.tool, "mcp__empty__a", 0),
        ], lanes: [], tips: [], commands: [], errors: [])
        let groups = s.causeGroups
        XCTAssertEqual(groups.map(\.title), ["Claude Code", "big", "small"])
        XCTAssertEqual(groups[0].causes.map(\.shortTitle), ["Your messages", "Bash"])
        XCTAssertEqual(groups[1].causes.map(\.shortTitle), ["a", "b"])
        XCTAssertEqual(groups[1].costMicros, 7)
        XCTAssertEqual(groups.flatMap(\.causes).count, s.shownCauses.count)
    }

    func testAGroupSaysWhatItsServerIs() {
        var box = cause(.tool, "mcp__plugin_maker_box__fold"); box.costMicros = 3
        var note = cause(.tool, "mcp__claude_ai_Note_Box__get"); note.costMicros = 2
        var first = cause(.tool, "mcp__notes__a"); first.costMicros = 5
        var second = cause(.tool, "mcp__notes__b"); second.costMicros = 4; second.serverDescription = "Notes are kept here."
        var silent = cause(.tool, "mcp__silent__a"); silent.costMicros = 1
        var bash = cause(.tool, "Bash"); bash.costMicros = 9
        let s = Spend(costMicros: 0, tokens: 0, causes: [box, note, first, second, silent, bash], lanes: [], tips: [], commands: [], errors: [])
        let about = Dictionary(uniqueKeysWithValues: s.causeGroups.map { ($0.title, $0.about ?? "") })
        XCTAssertEqual(about, ["Claude Code": "", "box": "plugin maker", "Note Box": "claude.ai connector", "notes": "Notes are kept here.", "silent": ""])
        box.serverDescription = "Box makes boxes."
        let both = Spend(costMicros: 0, tokens: 0, causes: [box], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(both.causeGroups.first?.about, "plugin maker · Box makes boxes.")
        XCTAssertEqual(s.causeGroups.map(\.isMCP), [false, true, true, true, true])
    }

    func testAPromptNamedLikeAServerToolStaysInClaudeCode() {
        var c = cause(.other, "mcp__notes__get_page"); c.costMicros = 1
        let s = Spend(costMicros: 0, tokens: 0, causes: [c], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(s.causeGroups.map(\.server), [nil])
    }

    func testCauseGroupsOfNothingAreEmpty() {
        let s = Spend(costMicros: 0, tokens: 0, causes: [], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(s.causeGroups, [])
    }

    func testShownCausesHaveTheMostCostFirstAndNoEmptyOnes() {
        var a = cause(.tool, "A"); a.costMicros = 1
        var b = cause(.tool, "B"); b.costMicros = 9
        var c = cause(.tool, "C"); c.count = 1
        let d = cause(.tool, "D")
        let s = Spend(costMicros: 0, tokens: 0, causes: [a, b, c, d], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(s.shownCauses.map(\.name), ["B", "A", "C"])
    }

    func testAToolNameFindsItsToolCauseOnly() {
        let s = Spend(costMicros: 0, tokens: 0, causes: [cause(.other, "Bash"), cause(.tool, "Bash"), cause(.tool, "Read")],
                      lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(s.cause(ofTool: "Bash")?.kind, .tool)
        XCTAssertEqual(s.cause(ofTool: "Read")?.name, "Read")
        XCTAssertNil(s.cause(ofTool: "Write"))
        let unnamed = Spend(costMicros: 0, tokens: 0, causes: [cause(.tool, "Tool")], lanes: [], tips: [], commands: [], errors: [])
        XCTAssertEqual(unnamed.cause(ofTool: "")?.name, "Tool")
    }

    /// The Anatomy tab's tool cards open the Cause tab: Rust must name both the same.
    func testEveryToolOfTheExampleHasACauseWithItsCalls() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        XCTAssertFalse(a.tools.isEmpty)
        for t in a.tools {
            XCTAssertEqual(a.spend.cause(ofTool: t.tool)?.count, t.calls, t.tool)
        }
    }

    /// The Rust code wrote these causes and their calls (spend.rs tests the rules):
    /// the Cause tab's list must add up to the cause it stands under.
    func testTheCallsOfEachCauseAddUpToTheCauseFromRust() throws {
        let a = try Anatomy.decode(Data(contentsOf: AnatomyContractTests.example))
        XCTAssertFalse(a.spend.causes.isEmpty)
        for c in a.spend.causes {
            if c.kind != .other { XCTAssertEqual(UInt64(c.items.count), c.count, c.name) }
            let sum = c.items.reduce(0) { $0 + $1.costMicros }
            // Each part is rounded on its own: at most 1 micro-dollar per call apart.
            XCTAssertLessThanOrEqual(abs(Int64(sum) - Int64(c.costMicros)), Int64(c.items.count) + 1, c.name)
            for item in c.items {
                let events = a.lane(item.lane)?.events ?? []
                XCTAssertTrue(events.indices.contains(item.event), "\(c.name): \(item)")
            }
        }
    }
}
