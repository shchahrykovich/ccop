// The tools and MCP servers of many sessions: `ccop tools --json`, added up
// for the sessions the list shows (period, search, folder).

import Foundation

/// `ccop tools --json`: one use per session and tool (`ToolsReport` in tools.rs).
public struct ToolsReport: Codable, Equatable, Sendable {
    public struct SessionRef: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var projectDir: String
        /// The whole session's cost.
        public var costMicros: UInt64
    }

    public struct Tool: Codable, Equatable, Sendable {
        public var name: String
        /// The MCP server as in the name (`plugin_playwright_playwright`); nil for Claude Code's tools.
        public var server: String?
        public var description: String?
        public var serverDescription: String?
    }

    public struct Use: Codable, Equatable, Sendable {
        /// Indexes in `sessions` and `tools`.
        public var session: Int
        public var tool: Int
        public var costMicros: UInt64
        public var calls: UInt64
        public var errors: UInt64
        public var ms: UInt64
    }

    /// One tool call: the costliest calls of each use, at most 20
    /// (`CALLS_PER_USE` in `tools.rs`).
    public struct Call: Codable, Equatable, Sendable {
        public var session: Int
        public var tool: Int
        public var lane: String
        /// A subagent's name; nil for the main lane.
        public var laneName: String?
        public var event: Int
        public var toolUseId: String?
        public var start: Date
        public var costMicros: UInt64
        public var ms: UInt64
        public var resultBytes: UInt64?
        public var isError: Bool
        public var text: String?
        public var command: String?
        public var group: String?

        public init(session: Int, tool: Int, lane: String = "main", laneName: String? = nil, event: Int, toolUseId: String? = nil,
                    start: Date = Date(timeIntervalSince1970: 0), costMicros: UInt64, ms: UInt64 = 0, resultBytes: UInt64? = nil,
                    isError: Bool = false, text: String? = nil, command: String? = nil, group: String? = nil) {
            self.session = session
            self.tool = tool
            self.lane = lane
            self.laneName = laneName
            self.event = event
            self.toolUseId = toolUseId
            self.start = start
            self.costMicros = costMicros
            self.ms = ms
            self.resultBytes = resultBytes
            self.isError = isError
            self.text = text
            self.command = command
            self.group = group
        }
    }

    /// The JSON keeps this many of the costliest calls of each session and
    /// tool, so the list of any sessions is right up to this many calls.
    public static let callsPerUse = 20

    public var sessions: [SessionRef]
    public var tools: [Tool]
    public var uses: [Use]
    public var calls: [Call]

    public init(sessions: [SessionRef], tools: [Tool], uses: [Use], calls: [Call] = []) {
        self.sessions = sessions
        self.tools = tools
        self.uses = uses
        self.calls = calls
    }

    public static func decode(_ data: Data) throws -> ToolsReport {
        try Session.makeDecoder().decode(ToolsReport.self, from: data)
    }
}

/// The left list's mode in the window: sessions, or tools and MCP servers.
public enum SidebarMode: String, CaseIterable, Sendable {
    case sessions, tools

    public static let defaultsKey = "sidebarMode"

    public var title: String {
        switch self {
        case .sessions: "Sessions"
        case .tools: "Tools"
        }
    }

    public static func load(_ defaults: UserDefaults = .standard) -> SidebarMode {
        defaults.string(forKey: defaultsKey).flatMap(SidebarMode.init(rawValue:)) ?? .sessions
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// What the Tools mode shows: all, one MCP server (its name as in the tool
/// names), or one tool (its whole name).
public enum ToolPick: Hashable, Sendable {
    case all
    case server(String)
    case tool(String)
}

public extension Period {
    /// `--since` for `ccop tools`: a period that holds every session the list
    /// can show for this period, with an hour or a day to spare.
    func cliSince(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .today:
            let minutes = Int(now.timeIntervalSince(calendar.startOfDay(for: now)) / 60)
            return "\(minutes + 60)m"
        case .week: return "8d"
        case .month: return "31d"
        // Flagged sessions can be of any age.
        case .all, .flagged: return "36500d"
        }
    }
}

/// One line of the Tools list: a server or a tool, added up over sessions.
public struct ToolTotal: Identifiable, Equatable, Sendable {
    public var pick: ToolPick
    /// `wiki`, `playwright`, `Bash`, `get_page`.
    public var title: String
    /// `plugin playwright`, `claude.ai connector`; nil when the name does not say.
    public var origin: String?
    public var description: String?
    public var costMicros: UInt64 = 0
    public var calls: UInt64 = 0
    public var errors: UInt64 = 0
    public var ms: UInt64 = 0
    public var sessions = 0
    public var projects = 0
    /// Tools of a server that were called; 1 for a tool.
    public var tools = 0
    public var id: ToolPick { pick }
}

/// A project's part of a server's or a tool's cost.
public struct ToolProjectShare: Identifiable, Equatable, Sendable {
    public var projectDir: String
    public var costMicros: UInt64
    public var sessions: Int
    public var id: String { projectDir }
    public var name: String { Self.name(projectDir) }

    /// The last part of a folder: `shop` for `/Users/me/shop`.
    public static func name(_ dir: String) -> String {
        let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return trimmed.components(separatedBy: "/").last.flatMap { $0.isEmpty ? nil : $0 } ?? dir
    }
}

/// A session that called a server or a tool.
public struct ToolSessionShare: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var projectDir: String
    /// The cost of the picked tools in this session.
    public var costMicros: UInt64
    public var calls: UInt64
    public var errors: UInt64
    /// The whole session's cost.
    public var sessionCostMicros: UInt64
    /// The costliest of the picked tools in this session: the Cause tab opens at it.
    public var topTool: String
    public var projectName: String { ToolProjectShare.name(projectDir) }
    /// The part of the session's cost, 0...1.
    public var share: Double { sessionCostMicros > 0 ? Double(costMicros) / Double(sessionCostMicros) : 0 }
}

/// The table of projects × tools: the cost and the sessions of each cell.
/// One tool call in the Tools mode, with its session.
public struct ToolCallRow: Identifiable, Equatable, Sendable {
    public var sessionID: String
    public var sessionTitle: String
    public var projectDir: String
    public var tool: String
    public var call: ToolsReport.Call
    public var id: String { "\(sessionID) \(call.lane) \(call.event)" }
    public var projectName: String { ToolProjectShare.name(projectDir) }
    /// What the call did: a Bash command, else a short form of the input.
    public var summary: String { call.command ?? call.text ?? ToolName(tool).short }
    /// The description of a Bash call, when the summary is its command.
    public var detail: String? { call.command != nil && call.text != call.command ? call.text : nil }
}

public struct ToolMatrix: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var costMicros: UInt64
        public var sessions: Int
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var pick: ToolPick
        public var title: String
        public var isMCP: Bool
        /// One per column; nil where the project did not use it.
        public var cells: [Cell?]
        public var id: ToolPick { pick }
    }

    /// Project folders, the most cost first.
    public var projects: [String]
    public var rows: [Row]
    /// The largest cell, for the shade of the others.
    public var maxCostMicros: UInt64

    /// 0...1 on a log scale from 1 cent to the largest cell, so small cells still show.
    public func shade(_ cell: Cell) -> Double {
        let low = 10_000.0
        let c = max(Double(cell.costMicros), low)
        let top = max(Double(maxCostMicros), low * 10)
        return min(1, max(0.05, log10(c / low) / log10(top / low)))
    }
}

/// The tools and servers of the sessions the list shows.
public struct ToolsData: Equatable, Sendable {
    private let report: ToolsReport
    /// Indexes of `report.uses` whose session is kept.
    private let uses: [Int]
    private let callIndices: [Int]
    public let sessionCount: Int
    /// All kept sessions' cost, tools or not.
    public let costMicros: UInt64
    public let servers: [ToolTotal]
    /// Claude Code's own tools.
    public let builtIns: [ToolTotal]
    /// Sessions that called an MCP server, and those that called two or more.
    public let mcpSessions: Int
    public let multiServerSessions: Int

    /// `keep`: the ids of the sessions to count; nil for all in the report.
    public init(report: ToolsReport, keep: Set<String>?) {
        self.report = report
        let kept = report.sessions.indices.filter { keep?.contains(report.sessions[$0].id) ?? true }
        let keptSet = Set(kept)
        uses = report.uses.indices.filter { keptSet.contains(report.uses[$0].session) && report.uses[$0].tool < report.tools.count }
        callIndices = report.calls.indices.filter { keptSet.contains(report.calls[$0].session) && report.calls[$0].tool < report.tools.count }
        sessionCount = kept.count
        costMicros = kept.reduce(0) { $0 + report.sessions[$1].costMicros }
        var serverSets: [Int: Set<String>] = [:]
        for i in uses {
            if let s = report.tools[report.uses[i].tool].server { serverSets[report.uses[i].session, default: []].insert(s) }
        }
        mcpSessions = serverSets.count
        multiServerSessions = serverSets.values.filter { $0.count >= 2 }.count
        servers = Self.totals(report, uses, key: { t in t.server.map { ToolPick.server($0) } })
        builtIns = Self.totals(report, uses, key: { t in t.server == nil ? ToolPick.tool(t.name) : nil })
    }

    /// The servers' part: cost, calls and errors.
    public var mcpCostMicros: UInt64 { servers.reduce(0) { $0 + $1.costMicros } }
    public var mcpCalls: UInt64 { servers.reduce(0) { $0 + $1.calls } }
    public var mcpErrors: UInt64 { servers.reduce(0) { $0 + $1.errors } }

    /// The server's or the tool's line; nil when the kept sessions did not call it.
    public func total(_ pick: ToolPick) -> ToolTotal? {
        switch pick {
        case .all: nil
        case .server: servers.first { $0.pick == pick }
        case let .tool(name):
            builtIns.first { $0.pick == pick } ?? Self.totals(report, uses, key: { $0.name == name ? pick : nil }).first
        }
    }

    /// The tools of one server, the most cost first.
    public func tools(ofServer server: String) -> [ToolTotal] {
        Self.totals(report, uses, key: { $0.server == server ? ToolPick.tool($0.name) : nil })
    }

    /// The server a tool comes from; nil for Claude Code's tools.
    public func server(ofTool name: String) -> String? {
        report.tools.first { $0.name == name }?.server
    }

    /// The projects that called a server or a tool, the most cost first.
    public func projects(_ pick: ToolPick) -> [ToolProjectShare] {
        var cost: [String: UInt64] = [:]
        var sessions: [String: Set<Int>] = [:]
        for i in uses where matches(pick, report.uses[i]) {
            let u = report.uses[i]
            let dir = report.sessions[u.session].projectDir
            cost[dir, default: 0] += u.costMicros
            sessions[dir, default: []].insert(u.session)
        }
        return cost.map { ToolProjectShare(projectDir: $0.key, costMicros: $0.value, sessions: sessions[$0.key]?.count ?? 0) }
            .sorted { ($0.costMicros, $1.projectDir) > ($1.costMicros, $0.projectDir) }
    }

    /// The sessions that called a server or a tool, the most cost first.
    public func sessions(_ pick: ToolPick) -> [ToolSessionShare] {
        var out: [Int: ToolSessionShare] = [:]
        var top: [Int: UInt64] = [:]
        for i in uses where matches(pick, report.uses[i]) {
            let u = report.uses[i]
            let s = report.sessions[u.session]
            let name = report.tools[u.tool].name
            var row = out[u.session] ?? ToolSessionShare(id: s.id, title: s.title, projectDir: s.projectDir, costMicros: 0, calls: 0,
                                                         errors: 0, sessionCostMicros: s.costMicros, topTool: name)
            row.costMicros += u.costMicros
            row.calls += u.calls
            row.errors += u.errors
            if u.costMicros > top[u.session, default: 0] || out[u.session] == nil {
                top[u.session] = u.costMicros
                row.topTool = name
            }
            out[u.session] = row
        }
        return out.values.sorted { ($0.costMicros, $1.id) > ($1.costMicros, $0.id) }
    }

    /// Projects × tools: Claude Code's costliest tools, then the servers.
    /// `columns` projects at most, the most cost first.
    /// The costliest calls of a tool or a server in the sessions kept, the
    /// most cost first. More than `ToolsReport.callsPerUse` could miss some.
    public func calls(_ pick: ToolPick, limit: Int = ToolsReport.callsPerUse) -> [ToolCallRow] {
        let picked = callIndices.filter { matches(pick, tool: report.calls[$0].tool) }
            .sorted { (report.calls[$0].costMicros, $1) > (report.calls[$1].costMicros, $0) }
        return picked.prefix(limit).map { i in
            let c = report.calls[i]
            let s = report.sessions[c.session]
            return ToolCallRow(sessionID: s.id, sessionTitle: s.title, projectDir: s.projectDir, tool: report.tools[c.tool].name, call: c)
        }
    }

    public func matrix(columns: Int = 8, builtIns builtInRows: Int = 9) -> ToolMatrix {
        var projectCost: [String: UInt64] = [:]
        for i in uses {
            projectCost[report.sessions[report.uses[i].session].projectDir, default: 0] += report.uses[i].costMicros
        }
        let projects = projectCost.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(columns).map(\.key)
        let column = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($1, $0) })
        let picks = Array(builtIns.prefix(builtInRows)) + servers
        var cells: [ToolPick: [Int: (UInt64, Set<Int>)]] = [:]
        for i in uses {
            let u = report.uses[i]
            guard let c = column[report.sessions[u.session].projectDir] else { continue }
            let t = report.tools[u.tool]
            let pick: ToolPick = t.server.map { .server($0) } ?? .tool(t.name)
            var cell = cells[pick, default: [:]][c] ?? (0, [])
            cell.0 += u.costMicros
            cell.1.insert(u.session)
            cells[pick, default: [:]][c] = cell
        }
        var maxCost: UInt64 = 0
        let rows = picks.map { total in
            let row = (0 ..< projects.count).map { c -> ToolMatrix.Cell? in
                guard let cell = cells[total.pick]?[c] else { return nil }
                maxCost = max(maxCost, cell.0)
                return ToolMatrix.Cell(costMicros: cell.0, sessions: cell.1.count)
            }
            if case .server = total.pick {
                return ToolMatrix.Row(pick: total.pick, title: total.title, isMCP: true, cells: row)
            }
            return ToolMatrix.Row(pick: total.pick, title: total.title, isMCP: false, cells: row)
        }
        return ToolMatrix(projects: projects, rows: rows, maxCostMicros: maxCost)
    }

    private func matches(_ pick: ToolPick, _ u: ToolsReport.Use) -> Bool {
        matches(pick, tool: u.tool)
    }

    private func matches(_ pick: ToolPick, tool: Int) -> Bool {
        let t = report.tools[tool]
        switch pick {
        case .all: return true
        case let .server(s): return t.server == s
        case let .tool(name): return t.name == name
        }
    }

    private static func totals(_ report: ToolsReport, _ uses: [Int], key: (ToolsReport.Tool) -> ToolPick?) -> [ToolTotal] {
        var totals: [ToolPick: ToolTotal] = [:]
        var sessions: [ToolPick: Set<Int>] = [:]
        var projects: [ToolPick: Set<String>] = [:]
        var tools: [ToolPick: Set<Int>] = [:]
        for i in uses {
            let u = report.uses[i]
            let t = report.tools[u.tool]
            guard let pick = key(t) else { continue }
            let name = ToolName(t.name)
            var total = totals[pick] ?? ToolTotal(
                pick: pick,
                title: { if case .server = pick { return name.server ?? t.server ?? t.name }; return name.short }(),
                origin: name.origin,
                description: { if case .server = pick { return t.serverDescription }; return t.description }()
            )
            if case .server = pick, total.description == nil { total.description = t.serverDescription }
            total.costMicros += u.costMicros
            total.calls += u.calls
            total.errors += u.errors
            total.ms += u.ms
            totals[pick] = total
            sessions[pick, default: []].insert(u.session)
            projects[pick, default: []].insert(report.sessions[u.session].projectDir)
            tools[pick, default: []].insert(u.tool)
        }
        return totals.values.map { t in
            var t = t
            t.sessions = sessions[t.pick]?.count ?? 0
            t.projects = projects[t.pick]?.count ?? 0
            t.tools = tools[t.pick]?.count ?? 0
            return t
        }
        .sorted { ($0.costMicros, $1.title) > ($1.costMicros, $0.title) }
    }
}
