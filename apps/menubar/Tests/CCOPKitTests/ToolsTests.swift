import Foundation
import XCTest
@testable import CCOPKit

/// api/tools.example.json is written by the Rust test
/// libs/core/tests/api_example.rs from the real code.
final class ToolsContractTests: XCTestCase {
    func testTheExampleDecodes() throws {
        let url = SessionContractTests.example.deletingLastPathComponent().appendingPathComponent("tools.example.json")
        let r = try ToolsReport.decode(Data(contentsOf: url))
        XCTAssertEqual(r.sessions.count, 2)
        XCTAssertEqual(r.sessions[0].projectDir, "/Users/me/shop")
        XCTAssertGreaterThan(r.sessions[0].costMicros, 0)
        XCTAssertEqual(r.tools.map(\.server), [nil, "plugin_box_box", "wiki", "wiki"])
        XCTAssertEqual(r.uses.count, 5)
        let data = ToolsData(report: r, keep: nil)
        XCTAssertEqual(Set(data.servers.map(\.title)), ["wiki", "box"])
        XCTAssertEqual(data.builtIns.map(\.title), ["Bash"])
        XCTAssertEqual(data.builtIns[0].errors, 1)
    }
}

final class ToolsDataTests: XCTestCase {
    private func use(_ s: Int, _ t: Int, _ cost: UInt64, calls: UInt64 = 1, errors: UInt64 = 0) -> ToolsReport.Use {
        ToolsReport.Use(session: s, tool: t, costMicros: cost, calls: calls, errors: errors, ms: 1000)
    }

    /// Three sessions in two made-up projects:
    /// s1 (garden): Bash $3, wiki get_page $1, wiki search $0.50 (1 error), box open $0.20
    /// s2 (garden): Bash $1, Read $0.40
    /// s3 (bakery): wiki get_page $2
    private var report: ToolsReport {
        ToolsReport(
            sessions: [
                .init(id: "s1", title: "Plant the beds", projectDir: "/made/up/garden", costMicros: 10_000_000),
                .init(id: "s2", title: "Water", projectDir: "/made/up/garden", costMicros: 2_000_000),
                .init(id: "s3", title: "Bake", projectDir: "/made/up/bakery", costMicros: 4_000_000),
            ],
            tools: [
                .init(name: "Bash", server: nil, description: "Runs a command", serverDescription: nil),
                .init(name: "Read", server: nil, description: nil, serverDescription: nil),
                .init(name: "mcp__wiki__get_page", server: "wiki", description: nil, serverDescription: "A wiki of notes."),
                .init(name: "mcp__wiki__search", server: "wiki", description: nil, serverDescription: nil),
                .init(name: "mcp__plugin_box_box__open", server: "plugin_box_box", description: nil, serverDescription: nil),
            ],
            uses: [
                use(0, 0, 3_000_000, calls: 5), use(0, 2, 1_000_000), use(0, 3, 500_000, calls: 2, errors: 1), use(0, 4, 200_000),
                use(1, 0, 1_000_000), use(1, 1, 400_000),
                use(2, 2, 2_000_000, calls: 3),
            ]
        )
    }

    func testServersAddUpTheirToolsAndCountEachSessionOnce() throws {
        let d = ToolsData(report: report, keep: nil)
        XCTAssertEqual(d.sessionCount, 3)
        XCTAssertEqual(d.costMicros, 16_000_000)
        XCTAssertEqual(d.servers.map(\.pick), [.server("wiki"), .server("plugin_box_box")])
        let wiki = d.servers[0]
        XCTAssertEqual(wiki.title, "wiki")
        XCTAssertEqual(wiki.description, "A wiki of notes.")
        XCTAssertEqual(wiki.costMicros, 3_500_000)
        XCTAssertEqual(wiki.calls, 6)
        XCTAssertEqual(wiki.errors, 1)
        XCTAssertEqual(wiki.sessions, 2)
        XCTAssertEqual(wiki.projects, 2)
        XCTAssertEqual(wiki.tools, 2)
        XCTAssertEqual(d.servers[1].title, "box")
        XCTAssertEqual(d.servers[1].origin, "plugin box")
        XCTAssertEqual(d.builtIns.map(\.title), ["Bash", "Read"])
        XCTAssertEqual(d.builtIns[0].sessions, 2)
        XCTAssertEqual(d.mcpCostMicros, 3_700_000)
        XCTAssertEqual(d.mcpCalls, 7)
        XCTAssertEqual(d.mcpErrors, 1)
    }

    func testMCPSessionsCountOneServerAndTwoOrMore() {
        let d = ToolsData(report: report, keep: nil)
        XCTAssertEqual(d.mcpSessions, 2)
        XCTAssertEqual(d.multiServerSessions, 1, "s1 called wiki and box")
    }

    func testOnlyTheKeptSessionsCount() {
        let d = ToolsData(report: report, keep: ["s2", "s3"])
        XCTAssertEqual(d.sessionCount, 2)
        XCTAssertEqual(d.costMicros, 6_000_000)
        XCTAssertEqual(d.servers.map(\.pick), [.server("wiki")])
        XCTAssertEqual(d.servers[0].costMicros, 2_000_000)
        XCTAssertEqual(d.servers[0].tools, 1)
        XCTAssertEqual(d.mcpSessions, 1)
        XCTAssertEqual(d.multiServerSessions, 0)
        XCTAssertNil(d.total(.server("plugin_box_box")))
        XCTAssertEqual(ToolsData(report: report, keep: []).sessionCount, 0)
    }

    func testTheToolsOfAServerHaveShortTitles() {
        let d = ToolsData(report: report, keep: nil)
        let tools = d.tools(ofServer: "wiki")
        XCTAssertEqual(tools.map(\.title), ["get_page", "search"])
        XCTAssertEqual(tools.map(\.pick), [.tool("mcp__wiki__get_page"), .tool("mcp__wiki__search")])
        XCTAssertEqual(tools[0].sessions, 2)
        XCTAssertEqual(d.total(.tool("mcp__wiki__search"))?.errors, 1)
        XCTAssertEqual(d.server(ofTool: "mcp__wiki__search"), "wiki")
        XCTAssertNil(d.server(ofTool: "Bash"))
    }

    func testProjectsOfAServerHaveTheMostCostFirst() {
        let projects = ToolsData(report: report, keep: nil).projects(.server("wiki"))
        XCTAssertEqual(projects.map(\.name), ["bakery", "garden"])
        XCTAssertEqual(projects.map(\.costMicros), [2_000_000, 1_500_000])
        XCTAssertEqual(projects.map(\.sessions), [1, 1])
    }

    func testSessionsOfAServerSayTheirShareAndTheCostliestTool() {
        let sessions = ToolsData(report: report, keep: nil).sessions(.server("wiki"))
        XCTAssertEqual(sessions.map(\.id), ["s3", "s1"])
        let s1 = sessions[1]
        XCTAssertEqual(s1.costMicros, 1_500_000)
        XCTAssertEqual(s1.calls, 3)
        XCTAssertEqual(s1.errors, 1)
        XCTAssertEqual(s1.topTool, "mcp__wiki__get_page")
        XCTAssertEqual(s1.share, 0.15, accuracy: 1e-9)
        XCTAssertEqual(s1.projectName, "garden")
        let bash = ToolsData(report: report, keep: nil).sessions(.tool("Bash"))
        XCTAssertEqual(bash.map(\.id), ["s1", "s2"])
        XCTAssertEqual(bash[0].topTool, "Bash")
    }

    func testTheMatrixHasClaudeCodesToolsThenServersByProject() {
        let m = ToolsData(report: report, keep: nil).matrix()
        XCTAssertEqual(m.projects, ["/made/up/garden", "/made/up/bakery"])
        XCTAssertEqual(m.rows.map(\.title), ["Bash", "Read", "wiki", "box"])
        XCTAssertEqual(m.rows.map(\.isMCP), [false, false, true, true])
        let wiki = m.rows[2]
        XCTAssertEqual(wiki.cells[0], ToolMatrix.Cell(costMicros: 1_500_000, sessions: 1))
        XCTAssertEqual(wiki.cells[1], ToolMatrix.Cell(costMicros: 2_000_000, sessions: 1))
        XCTAssertNil(m.rows[1].cells[1], "the bakery did not read")
        XCTAssertEqual(m.rows[0].cells[0], ToolMatrix.Cell(costMicros: 4_000_000, sessions: 2))
        XCTAssertEqual(m.maxCostMicros, 4_000_000)
        XCTAssertEqual(m.shade(ToolMatrix.Cell(costMicros: 4_000_000, sessions: 1)), 1)
        XCTAssertLessThan(m.shade(ToolMatrix.Cell(costMicros: 200_000, sessions: 1)), m.shade(ToolMatrix.Cell(costMicros: 2_000_000, sessions: 1)))
        XCTAssertEqual(m.shade(ToolMatrix.Cell(costMicros: 1, sessions: 1)), 0.05, "a tiny cell still shows")
    }

    func testTheMatrixKeepsTheCostliestProjectsAndTools() {
        let m = ToolsData(report: report, keep: nil).matrix(columns: 1, builtIns: 1)
        XCTAssertEqual(m.projects, ["/made/up/garden"])
        XCTAssertEqual(m.rows.map(\.title), ["Bash", "wiki", "box"])
    }

    func testTheCLIPeriodHoldsTheWholeListPeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 11, minute: 30)))
        XCTAssertEqual(Period.today.cliSince(now: now, calendar: calendar), "750m")
        XCTAssertEqual(Period.week.cliSince(now: now, calendar: calendar), "8d")
        XCTAssertEqual(Period.month.cliSince(now: now, calendar: calendar), "31d")
        XCTAssertEqual(Period.all.cliSince(now: now, calendar: calendar), "36500d")
        XCTAssertEqual(Period.flagged.cliSince(now: now, calendar: calendar), "36500d")
    }

    func testTheSidebarModeIsSaved() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ccop.tests.sidebarMode"))
        defaults.removePersistentDomain(forName: "ccop.tests.sidebarMode")
        XCTAssertEqual(SidebarMode.load(defaults), .sessions)
        SidebarMode.tools.save(defaults)
        XCTAssertEqual(SidebarMode.load(defaults), .tools)
        defaults.set("nothing", forKey: SidebarMode.defaultsKey)
        XCTAssertEqual(SidebarMode.load(defaults), .sessions)
    }
}
