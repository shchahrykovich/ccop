import CCOPKit
import SwiftUI

// The window's Tools mode: the MCP servers and Claude Code's tools of the
// sessions the list keeps (period, search, folder), and which projects and
// sessions called them.

/// The left list in Tools mode: All tools, then the servers, then Claude Code's tools.
struct ToolsSidebarList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let d = model.toolsData {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ToolListRow(title: "All tools", detail: "\(sessions(d.sessionCount)) · \(d.servers.count) MCP server\(d.servers.count == 1 ? "" : "s")",
                                costMicros: d.costMicros, symbol: "square.grid.2x2", color: Theme.accent,
                                selected: model.toolPick == .all) { model.toolPick = .all }
                        .padding(.top, 4)
                    if !d.servers.isEmpty {
                        header("MCP servers", d.mcpCostMicros)
                        ForEach(d.servers) { t in
                            row(t, d, detail: "\(sessions(t.sessions)) · \(t.tools) tool\(t.tools == 1 ? "" : "s")",
                                symbol: "server.rack", color: Theme.grep)
                        }
                    }
                    if !d.builtIns.isEmpty {
                        header("Claude Code tools", d.builtIns.reduce(0) { $0 + $1.costMicros })
                        ForEach(d.builtIns) { t in
                            let look = Theme.tool(t.title)
                            row(t, d, detail: sessions(t.sessions) + (t.errors > 0 ? " · \(t.errors.formatted()) error\(t.errors == 1 ? "" : "s")" : ""),
                                symbol: look.symbol, color: look.color)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        } else if let error = model.toolsError {
            Text(error).foregroundStyle(Theme.warn).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).textSelection(.enabled)
        } else {
            ProgressView("Reading the tools…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ title: String, _ cost: UInt64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Format.dollars(cost)).monospacedDigit()
        }
        .font(.ui(11, .semibold))
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(height: 32)
    }

    private func row(_ t: ToolTotal, _ d: ToolsData, detail: String, symbol: String, color: Color) -> some View {
        // A server's row stays chosen while one of its tools is shown.
        let chosen: Bool = switch (model.toolPick, t.pick) {
        case let (.tool(name), .server(server)): d.server(ofTool: name) == server
        default: model.toolPick == t.pick
        }
        return ToolListRow(title: t.title, detail: detail, costMicros: t.costMicros, symbol: symbol, color: color,
                           selected: chosen) { model.toolPick = t.pick }
            .help(t.description ?? t.title)
    }
}

private func sessions(_ n: Int) -> String {
    "\(n.formatted()) session\(n == 1 ? "" : "s")"
}

private struct ToolListRow: View {
    let title: String
    let detail: String
    let costMicros: UInt64
    let symbol: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, color: selected ? .white : color, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(detail).font(.ui(11)).foregroundStyle(selected ? .white.opacity(0.85) : Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Format.dollars(costMicros)).fontWeight(.medium).monospacedDigit()
            }
            .foregroundStyle(selected ? Color.white : Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The right side in Tools mode: all tools, or one server or tool.
struct ToolsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .titleBarArea()
            Rectangle().fill(Theme.line).frame(height: 1)
            if let d = model.toolsData {
                ScrollView {
                    Group {
                        switch model.toolPick {
                        case .all: ToolsOverview(data: d)
                        default: ToolDetail(data: d, pick: model.toolPick)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A new pick starts at the top.
                .id(model.toolPick)
            } else if let error = model.toolsError {
                VStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).textSelection(.enabled)
                    Button("Try again") { model.loadTools() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Reading the tools of each session…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let up = parent {
                HeaderIconButton(symbol: "chevron.left", help: "Back to \(up.title)", iconSize: 13) { model.toolPick = up.pick }
                    .keyboardShortcut("[", modifiers: .command)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.ui(15, .semibold)).lineLimit(1)
                Text("\(model.period.title) · the sessions of the list").font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 12)
            if model.toolsLoading {
                ProgressView().controlSize(.small).frame(width: 28, height: 28).help("Reading the tools…")
            } else {
                HeaderIconButton(symbol: "arrow.clockwise", help: "Read the tools again", iconSize: 14) { model.loadTools() }
            }
        }
    }

    private var title: String {
        switch model.toolPick {
        case .all: return "All tools"
        case let pick: return model.toolsData?.total(pick)?.title ?? "Tools"
        }
    }

    /// Where Back goes: a server's tool → the server; a server or Claude Code's tool → All tools.
    private var parent: (pick: ToolPick, title: String)? {
        switch model.toolPick {
        case .all: return nil
        case .server: return (.all, "All tools")
        case let .tool(name):
            if let server = model.toolsData?.server(ofTool: name) {
                return (.server(server), model.toolsData?.total(.server(server))?.title ?? server)
            }
            return (.all, "All tools")
        }
    }
}

// MARK: All tools

private struct ToolsOverview: View {
    @Environment(AppModel.self) private var model
    let data: ToolsData

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if data.sessionCount == 0 {
                Text("No sessions in this list.").foregroundStyle(Theme.text3)
            } else {
                cards
                ToolMatrixView(matrix: data.matrix())
            }
        }
    }

    private var cards: some View {
        let shared = data.servers.max { ($0.sessions, $1.costMicros) < ($1.sessions, $0.costMicros) }
        let top = data.builtIns.first
        return HStack(spacing: 12) {
            StatCard(label: "Sessions that called MCP", value: "\(data.mcpSessions.formatted()) of \(data.sessionCount.formatted())",
                     detail: "\(data.multiServerSessions.formatted()) of them called 2 servers or more", big: true)
            StatCard(label: "MCP cost", value: Format.dollars(data.mcpCostMicros),
                     detail: "\(percent(data.mcpCostMicros, of: data.costMicros)) of all · \(data.mcpCalls.formatted()) calls · \(data.mcpErrors.formatted()) errors",
                     big: true)
            StatCard(label: "Most shared server", value: shared?.title ?? "–",
                     detail: shared.map { "\(sessions($0.sessions)) in \($0.projects) project\($0.projects == 1 ? "" : "s")" } ?? "no MCP calls",
                     big: true)
            StatCard(label: "Costliest Claude Code tool", value: top.map { "\($0.title) \(Format.dollars($0.costMicros))" } ?? "–",
                     detail: top.map { "\(percent($0.costMicros, of: data.costMicros)) of all · \(sessions($0.sessions))" }, big: true)
        }
    }
}

private func percent(_ part: UInt64, of whole: UInt64) -> String {
    whole > 0 ? Format.percent(Double(part) / Double(whole)) : "0%"
}

/// Projects × tools: the cost and the sessions of each cell, darker for more cost.
private struct ToolMatrixView: View {
    @Environment(AppModel.self) private var model
    let matrix: ToolMatrix
    private let nameWidth: CGFloat = 170
    private let cellWidth: CGFloat = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Which project uses which tool").font(.ui(13, .semibold))
                Text("cost and sessions in each cell; darker is more cost. Click a row to see its sessions.")
                    .font(.ui(11)).foregroundStyle(Theme.text3)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Tool").frame(width: nameWidth, alignment: .leading)
                        ForEach(matrix.projects, id: \.self) { dir in
                            Text(ToolProjectShare.name(dir))
                                .lineLimit(2).multilineTextAlignment(.trailing)
                                .frame(width: cellWidth, alignment: .trailing)
                                .help(Theme.shortPath(dir))
                        }
                    }
                    .font(.ui(11, .medium))
                    .foregroundStyle(Theme.text3)
                    .padding(.bottom, 4)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ForEach(Array(matrix.rows.enumerated()), id: \.element.id) { i, row in
                        if i == 0 || matrix.rows[i - 1].isMCP != row.isMCP {
                            Text(row.isMCP ? "MCP servers" : "Claude Code tools")
                                .font(.ui(11, .semibold)).foregroundStyle(Theme.text3)
                                .padding(.top, i == 0 ? 6 : 12).padding(.bottom, 2)
                        }
                        Button { model.toolPick = row.pick } label: {
                            HStack(spacing: 4) {
                                Text(row.title).lineLimit(1).frame(width: nameWidth, alignment: .leading)
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { c, cell in
                                    cellView(cell, project: matrix.projects[c], tool: row.title)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: ToolMatrix.Cell?, project: String, tool: String) -> some View {
        if let cell {
            let shade = matrix.shade(cell)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.dollars(cell.costMicros)).font(.ui(12, .medium)).monospacedDigit()
                Text(sessions(cell.sessions)).font(.ui(10)).opacity(0.85)
            }
            .foregroundStyle(shade > 0.55 ? Color.white : Theme.text)
            .frame(width: cellWidth - 16, alignment: .trailing)
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(Theme.accent.opacity(0.08 + 0.84 * shade), in: RoundedRectangle(cornerRadius: 5))
            .help("\(tool) in \(ToolProjectShare.name(project)): \(Format.dollars(cell.costMicros)) in \(sessions(cell.sessions))")
        } else {
            RoundedRectangle(cornerRadius: 5).fill(Theme.text.opacity(0.03)).frame(width: cellWidth, height: 38)
        }
    }
}

// MARK: One server or tool

private struct ToolDetail: View {
    @Environment(AppModel.self) private var model
    let data: ToolsData
    let pick: ToolPick

    var body: some View {
        if let total = data.total(pick) {
            VStack(alignment: .leading, spacing: 28) {
                about(total)
                cards(total)
                if case let .server(server) = pick {
                    HStack(alignment: .top, spacing: 32) {
                        ServerToolsTable(tools: data.tools(ofServer: server))
                            .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
                        ProjectBars(projects: data.projects(pick))
                            .frame(minWidth: 260, maxWidth: 380, alignment: .topLeading)
                    }
                } else {
                    ProjectBars(projects: data.projects(pick)).frame(maxWidth: 520, alignment: .leading)
                }
                ToolCallsTable(rows: data.calls(pick), totalCalls: total.calls, showsTool: pick.isServer)
                ToolSessionsTable(rows: data.sessions(pick), sessionCount: data.sessionCount)
            }
        } else {
            Text("No session in this list called it.").foregroundStyle(Theme.text3)
        }
    }

    private func about(_ t: ToolTotal) -> some View {
        let kind: String = switch pick {
        case .server: (["MCP server", t.origin].compactMap { $0 } + ["\(t.tools) tools called"]).joined(separator: " · ")
        case let .tool(name): data.server(ofTool: name).map { "Tool of the \(data.total(.server($0))?.title ?? $0) server" } ?? "Claude Code tool"
        case .all: ""
        }
        let full: String? = if case let .tool(name) = pick, name != t.title { name } else { nil }
        return VStack(alignment: .leading, spacing: 4) {
            Text(kind).font(.ui(12)).foregroundStyle(Theme.text2)
            if let full {
                Text(full).font(.mono(11)).foregroundStyle(Theme.text3).textSelection(.enabled)
            }
            if let d = t.description, !d.isEmpty {
                Text(d).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    private func cards(_ t: ToolTotal) -> some View {
        HStack(spacing: 12) {
            StatCard(label: "API-equivalent cost", value: Format.dollars(t.costMicros),
                     detail: pick.isServer
                         ? "\(percent(t.costMicros, of: data.costMicros)) of all · \(percent(t.costMicros, of: data.mcpCostMicros)) of MCP"
                         : "\(percent(t.costMicros, of: data.costMicros)) of all",
                     big: true)
            StatCard(label: "Sessions", value: "\(t.sessions.formatted()) of \(data.sessionCount.formatted())",
                     detail: "in \(t.projects) project\(t.projects == 1 ? "" : "s")", big: true)
            StatCard(label: "Calls", value: t.calls.formatted(),
                     detail: t.calls > 0 ? "\(Format.dollars(t.costMicros / t.calls)) per call on average" : nil, big: true)
            StatCard(label: "Errors", value: t.errors.formatted(),
                     detail: t.calls > 0 ? "\(Format.smallPercent(Double(t.errors) / Double(t.calls))) of calls" : nil, big: true)
            StatCard(label: "Tool time", value: Format.duration(Double(t.ms) / 1000),
                     detail: "calls sent together count once", big: true)
        }
    }
}

private extension ToolPick {
    var isServer: Bool {
        if case .server = self { return true }
        return false
    }
}

private struct SectionTitle: View {
    let title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.ui(13, .semibold))
            if let note {
                Text(note).font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
    }
}

/// The tools of one server; a click shows the tool.
private struct ServerToolsTable: View {
    @Environment(AppModel.self) private var model
    let tools: [ToolTotal]

    var body: some View {
        let top = max(tools.first?.costMicros ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Tools of this server", note: "click one to see its sessions")
            HStack(spacing: 8) {
                Text("Tool").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cost").frame(width: 76, alignment: .trailing)
                Text("Calls").frame(width: 60, alignment: .trailing)
                Text("Sessions").frame(width: 64, alignment: .trailing)
                Text("Errors").frame(width: 50, alignment: .trailing)
            }
            .font(.ui(11, .medium)).foregroundStyle(Theme.text3)
            Rectangle().fill(Theme.line).frame(height: 1)
            ForEach(tools) { t in
                Button { model.toolPick = t.pick } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).lineLimit(1)
                            Meter(value: Double(t.costMicros) / Double(top), color: Theme.accent, height: 3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.dollars(t.costMicros)).fontWeight(.medium).frame(width: 76, alignment: .trailing)
                        Text(t.calls.formatted()).frame(width: 60, alignment: .trailing)
                        Text(t.sessions.formatted()).frame(width: 64, alignment: .trailing)
                        Text(t.errors > 0 ? t.errors.formatted() : "–").foregroundStyle(Theme.text3).frame(width: 50, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverRow()
                .help(t.description ?? t.title)
            }
        }
    }
}

private struct ProjectBars: View {
    let projects: [ToolProjectShare]
    private let shown = 8

    var body: some View {
        let top = max(projects.first?.costMicros ?? 1, 1)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "By project")
            ForEach(projects.prefix(shown)) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(p.name).lineLimit(1).help(Theme.shortPath(p.projectDir))
                        Spacer(minLength: 8)
                        Text(Format.dollars(p.costMicros)).fontWeight(.medium)
                        Text(sessions(p.sessions)).font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                    .monospacedDigit()
                    Meter(value: Double(p.costMicros) / Double(top), color: Theme.cacheWrite, height: 5)
                }
            }
            if projects.count > shown {
                let rest = projects.dropFirst(shown)
                Text("\(rest.count) more projects: \(Format.dollars(rest.reduce(0) { $0 + $1.costMicros }))")
                    .font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
    }
}

/// The sessions that called the server or the tool; a click opens the
/// session at its Cause tab, on the costliest of those tools.
private struct ToolSessionsTable: View {
    @Environment(AppModel.self) private var model
    let rows: [ToolSessionShare]
    let sessionCount: Int
    @State private var sort = TableSort<Column>()
    @State private var limit = 50

    enum Column { case calls, errors, cost, share }

    var body: some View {
        let sorted = sort.sorted(rows) { column, a, b in
            switch column {
            case .calls: a.calls < b.calls
            case .errors: a.errors < b.errors
            case .cost: a.costMicros < b.costMicros
            case .share: a.share < b.share
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Sessions that called it",
                         note: "\(rows.count.formatted()) of \(sessionCount.formatted()) · click one to open it at its Cause tab")
            HStack(spacing: 8) {
                Text("Session").frame(maxWidth: .infinity, alignment: .leading)
                Text("Project").frame(width: 170, alignment: .leading)
                SortTitle(title: "Calls", column: Column.calls, sort: $sort).frame(width: 60 + SortTitle<Column>.arrowRoom, alignment: .trailing)
                SortTitle(title: "Errors", column: Column.errors, sort: $sort).frame(width: 50 + SortTitle<Column>.arrowRoom, alignment: .trailing)
                SortTitle(title: "Cost", column: Column.cost, sort: $sort).frame(width: 76 + SortTitle<Column>.arrowRoom, alignment: .trailing)
                SortTitle(title: "Of session", column: Column.share, sort: $sort,
                          help: "Its part of the whole session's cost; sort by it")
                    .frame(width: 130 + SortTitle<Column>.arrowRoom, alignment: .trailing)
            }
            .font(.ui(11, .medium)).foregroundStyle(Theme.text3)
            Rectangle().fill(Theme.line).frame(height: 1)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sorted.prefix(limit)) { r in
                    Button { model.openToolInSession(r.id, tool: r.topTool) } label: {
                        HStack(spacing: 8) {
                            Text(r.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(r.projectName).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 170, alignment: .leading)
                            Text(r.calls.formatted()).frame(width: 60 + SortTitle<Column>.arrowRoom, alignment: .trailing)
                            Text(r.errors > 0 ? r.errors.formatted() : "–").foregroundStyle(Theme.text3)
                                .frame(width: 50 + SortTitle<Column>.arrowRoom, alignment: .trailing)
                            Text(Format.dollars(r.costMicros)).fontWeight(.medium).frame(width: 76 + SortTitle<Column>.arrowRoom, alignment: .trailing)
                            Text("\(Format.percent(r.share)) of \(Format.dollars(r.sessionCostMicros))").foregroundStyle(Theme.text2)
                                .frame(width: 130 + SortTitle<Column>.arrowRoom, alignment: .trailing)
                        }
                        .monospacedDigit()
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverRow()
                    .help(r.title)
                    .contextMenu {
                        Button("Open at Cause: \(ToolName(r.topTool).short)") { model.openToolInSession(r.id, tool: r.topTool) }
                        Button("Copy Session ID") { model.copy(r.id) }
                    }
                    Rectangle().fill(Theme.line2).frame(height: 1)
                }
            }
            if rows.count > limit {
                Button("Show \(min(50, rows.count - limit)) more") { limit += 50 }
                    .buttonStyle(DesignButtonStyle())
                    .padding(.top, 6)
            }
        }
    }
}

/// The costliest single calls of a tool or a server in the sessions of the
/// list. A click shows the whole call; Go to Chat opens its session.
private struct ToolCallsTable: View {
    @Environment(AppModel.self) private var model
    let rows: [ToolCallRow]
    let totalCalls: UInt64
    let showsTool: Bool
    @State private var sort = TableSort<Column>()
    @State private var shown: ToolCallRow?

    enum Column { case time, output, cost }

    private let room = SortTitle<Column>.arrowRoom

    var body: some View {
        if !rows.isEmpty {
            let sorted = sort.sorted(rows) { column, a, b in
                switch column {
                case .time: a.call.ms < b.call.ms
                case .output: (a.call.resultBytes ?? 0) < (b.call.resultBytes ?? 0)
                case .cost: a.call.costMicros < b.call.costMicros
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: "Costliest calls",
                             note: "the \(rows.count.formatted()) costliest of \(totalCalls.formatted()) · cost: its part of the model call after it · click one to see it in full")
                HStack(spacing: 8) {
                    Text("Call").frame(maxWidth: .infinity, alignment: .leading)
                    if showsTool { Text("Tool").frame(width: 130, alignment: .leading) }
                    Text("Session").frame(width: 240, alignment: .leading)
                    SortTitle(title: "Time", column: Column.time, sort: $sort, help: "From the call to its result")
                        .frame(width: 56 + room, alignment: .trailing)
                    SortTitle(title: "Output", column: Column.output, sort: $sort).frame(width: 64 + room, alignment: .trailing)
                    SortTitle(title: "Cost", column: Column.cost, sort: $sort).frame(width: 64 + room, alignment: .trailing)
                }
                .font(.ui(11, .medium)).foregroundStyle(Theme.text3)
                Rectangle().fill(Theme.line).frame(height: 1)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted) { r in
                        row(r)
                        Rectangle().fill(Theme.line2).frame(height: 1)
                    }
                }
            }
            .sheet(item: $shown) { r in ToolCallSheet(row: r) }
        }
    }

    private func row(_ r: ToolCallRow) -> some View {
        Button { shown = r } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if r.call.isError {
                            Image(systemName: "exclamationmark.circle.fill").font(.ui(11)).foregroundStyle(Theme.warn).help("The call failed")
                        }
                        Text(r.summary).font(.mono(12)).lineLimit(1).truncationMode(.tail)
                    }
                    if let detail = r.detail {
                        Text(detail).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsTool {
                    Text(ToolName(r.tool).short).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 130, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.sessionTitle).lineLimit(1)
                    Text(([r.projectName] + [r.call.laneName].compactMap { $0 }).joined(separator: " · "))
                        .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .frame(width: 240, alignment: .leading)
                Text(Format.duration(Double(r.call.ms) / 1000)).foregroundStyle(Theme.text2).frame(width: 56 + room, alignment: .trailing)
                Text(r.call.resultBytes.map { Format.bytes($0) } ?? "–").foregroundStyle(Theme.text2).frame(width: 64 + room, alignment: .trailing)
                Text(Format.dollars(r.call.costMicros)).fontWeight(.medium).frame(width: 64 + room, alignment: .trailing)
            }
            .monospacedDigit()
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow()
        .help([r.call.text, r.call.command].compactMap { $0 }.joined(separator: "\n\n"))
        .contextMenu {
            Button("View") { shown = r }
            Button("Go to Chat") { model.openCallInSession(r.sessionID, lane: r.call.lane, event: r.call.event) }
            Button("Open at Cause: \(ToolName(r.tool).short)") { model.openToolInSession(r.sessionID, tool: r.tool) }
            Divider()
            Button(r.call.command != nil ? "Copy Command" : "Copy Text") { model.copy(r.summary) }
            Button("Copy Session ID") { model.copy(r.sessionID) }
        }
    }
}

/// One call of the Tools mode in full. It has no anatomy of its session, so
/// it shows what `ccop tools` says about the call, then its input and output.
private struct ToolCallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: ToolCallRow

    var body: some View {
        let c = row.call
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(ToolName(row.tool).short).font(.title3.weight(.semibold))
                if let g = c.group { Text(g).font(.callout.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                Button("Go to Chat") {
                    dismiss()
                    model.openCallInSession(row.sessionID, lane: c.lane, event: c.event)
                }
                .help("Close this, open the session and show this call in its Chat tab")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(([row.sessionTitle, row.projectName, c.laneName ?? "Main session",
                   c.start.formatted(date: .abbreviated, time: .standard)] + [c.text].compactMap { $0 }).joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                fact("Time", Format.duration(Double(c.ms) / 1000))
                fact("Output", c.resultBytes.map { Format.bytes($0) } ?? "no result")
                fact("Cost", "\(Format.dollars(c.costMicros)), its part of the model call after it", bold: true)
            }
            .font(.callout)
            .textSelection(.enabled)
            Divider()
            CallInputOutput(sessionID: row.sessionID, toolUseID: c.toolUseId)
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 920, minHeight: 480, idealHeight: 720)
        .closesOnClickOutside { dismiss() }
    }

    private func fact(_ name: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).fontWeight(bold ? .semibold : .regular).monospacedDigit()
        }
    }
}
