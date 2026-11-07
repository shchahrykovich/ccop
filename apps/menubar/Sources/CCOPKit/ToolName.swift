import Foundation

/// A tool's name in parts. Claude Code names an MCP tool
/// `mcp__<server>__<tool>`; a plugin's server is `plugin_<plugin>_<server>`
/// and a claude.ai connector's is `claude_ai_<server>`.
public struct ToolName: Equatable, Sendable {
    /// `wiki`. Nil for a tool that is not from an MCP server.
    public let server: String?
    /// `get_page`, or the whole name for a tool that is not from an MCP server.
    public let short: String
    /// Where the server comes from, when the name says: `claude.ai connector`, `plugin playwright`.
    public let origin: String?

    public init(_ name: String) {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty, !parts[2].isEmpty else {
            server = nil
            short = name
            origin = nil
            return
        }
        server = Self.serverName(parts[1])
        origin = Self.origin(parts[1])
        short = parts.dropFirst(2).joined(separator: "__")
    }

    private static func serverName(_ raw: String) -> String {
        if raw.hasPrefix("plugin_") {
            let rest = raw.dropFirst("plugin_".count)
            if let end = rest.firstIndex(of: "_") {
                return String(rest[rest.index(after: end)...]).replacingOccurrences(of: "_", with: " ")
            }
            return String(rest)
        }
        if raw.hasPrefix("claude_ai_") {
            return raw.dropFirst("claude_ai_".count).replacingOccurrences(of: "_", with: " ")
        }
        return raw
    }

    private static func origin(_ raw: String) -> String? {
        if raw.hasPrefix("claude_ai_") { return "claude.ai connector" }
        guard raw.hasPrefix("plugin_") else { return nil }
        let rest = raw.dropFirst("plugin_".count)
        return "plugin \(rest.prefix { $0 != "_" })"
    }

    /// The SF Symbol for what the tool does, from the words of its name: the
    /// first word with a symbol wins. The default is the symbol of any other tool.
    public var symbol: String {
        if server == nil, let builtIn = Self.builtIn[short] { return builtIn }
        for word in short.lowercased().components(separatedBy: "_") {
            if let symbol = Self.words[word] { return symbol }
        }
        return "wrench.and.screwdriver"
    }

    private static let builtIn = [
        "AskUserQuestion": "questionmark.bubble",
        "Artifact": "doc.richtext",
        "Skill": "book.closed",
        "TodoWrite": "checklist",
        "ToolSearch": "magnifyingglass",
    ]

    private static let words: [String: String] = {
        let groups: [(String, [String])] = [
            ("magnifyingglass", ["search", "find", "query", "lookup"]),
            ("list.bullet", ["list"]),
            ("arrow.down.doc", ["get", "read", "fetch", "download", "export"]),
            ("arrow.up.doc", ["upload", "begin", "finish"]),
            ("square.and.pencil", ["put", "create", "add", "update", "set", "write", "edit", "fill"]),
            ("trash", ["delete", "remove", "trash"]),
            ("xmark.circle", ["close", "cancel"]),
            ("paperplane", ["send", "reply", "forward", "post"]),
            ("cursorarrow.click", ["click", "hover", "drag", "press", "type"]),
            ("safari", ["navigate", "browser"]),
            ("macwindow", ["tabs", "page", "window"]),
            ("curlybraces", ["javascript", "evaluate", "code"]),
            ("desktopcomputer", ["computer"]),
            ("camera", ["screenshot", "snapshot"]),
        ]
        var out: [String: String] = [:]
        for (symbol, words) in groups { for w in words { out[w] = symbol } }
        return out
    }()
}

/// The causes of one server, or the ones that come from no server.
public struct CauseGroup: Equatable, Sendable, Identifiable {
    /// Nil for Claude Code's own tools, your messages, compactions and the start.
    public let server: String?
    public let causes: [Cause]
    public var title: String { server ?? "Claude Code" }
    /// True for an MCP server's group.
    public var isMCP: Bool { server != nil }
    /// What the server is, as far as the transcript tells:
    /// `plugin box · Box makes boxes.` Nil when it does not tell.
    public var about: String? {
        guard server != nil else { return nil }
        let origin = causes.lazy.compactMap { ToolName($0.name).origin }.first
        let description = causes.lazy.compactMap(\.serverDescription).first { !$0.isEmpty }
        let parts = [origin, description].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    public var costMicros: UInt64 { causes.reduce(0) { $0 + $1.costMicros } }
    public var id: String { server.map { "server \($0)" } ?? "claude code" }
}

public extension Cause {
    /// The name in a list where the server is already said: `get_page`, `Bash`.
    var shortTitle: String {
        kind == .tool ? ToolName(name).short : title
    }

    var server: String? {
        kind == .tool ? ToolName(name).server : nil
    }
}

public extension Spend {
    /// `shownCauses` by server: first what comes from no server, then the
    /// servers, the most cost first. Inside a group the most cost comes first.
    var causeGroups: [CauseGroup] {
        let shown = shownCauses
        var servers: [String] = []
        var byServer: [String: [Cause]] = [:]
        var own: [Cause] = []
        for c in shown {
            guard let s = c.server else { own.append(c); continue }
            if byServer[s] == nil { servers.append(s) }
            byServer[s, default: []].append(c)
        }
        let groups = servers.map { CauseGroup(server: $0, causes: byServer[$0] ?? []) }
            .sorted { ($0.costMicros, $1.title) > ($1.costMicros, $0.title) }
        return own.isEmpty ? groups : [CauseGroup(server: nil, causes: own)] + groups
    }
}
