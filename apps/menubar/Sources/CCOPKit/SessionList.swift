// What the popover shows: sessions of a period that match a search, in
// day sections, with totals.

import Foundation

public enum Period: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all

    public var id: String { rawValue }

    public static let defaultsKey = "period"

    /// The period chosen last; Today the first time, or for an unknown value.
    public static func load(_ defaults: UserDefaults = .standard) -> Period {
        defaults.string(forKey: defaultsKey).flatMap(Period.init(rawValue:)) ?? .today
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All"
        }
    }

    /// The first moment that belongs to the period; nil for all time.
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .day, value: -30, to: now)
        case .all: nil
        }
    }
}

public struct DaySection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public var title: String
    public var sessions: [Session]
    public var usage: TokenUsage
}

/// One entry of the folder menu: a project folder and its sessions in the period.
public struct FolderChoice: Identifiable, Equatable, Sendable {
    public var id: String { path }
    /// The project folder without a trailing slash.
    public var path: String
    /// The folder name; with its parent when two folders have the same name.
    public var label: String
    public var sessions: Int

    public init(path: String, label: String, sessions: Int) {
        self.path = path
        self.label = label
        self.sessions = sessions
    }
}

/// Which folder the list shows: one folder alone, or a folder with all its
/// subfolders (for example its worktrees in `.claude/worktrees`).
public enum FolderScope: Codable, Equatable, Hashable, Sendable {
    case only(String)
    case withSubfolders(String)

    public static let defaultsKey = "folder"

    /// The folder chosen last; nil (all folders) the first time or for a
    /// saved value that cannot be read.
    public static func load(_ defaults: UserDefaults = .standard) -> FolderScope? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(FolderScope.self, from: $0) }
    }

    /// Nil is all folders: nothing is saved.
    public static func save(_ scope: FolderScope?, _ defaults: UserDefaults = .standard) {
        if let scope, let data = try? JSONEncoder().encode(scope) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    public var path: String {
        switch self {
        case let .only(p), let .withSubfolders(p): p
        }
    }

    /// Whether a session in `folder` belongs to the scope. Both paths are
    /// without a trailing slash.
    func contains(_ folder: String) -> Bool {
        switch self {
        case let .only(p): folder == p
        case let .withSubfolders(p): folder == p || folder.hasPrefix(p == "/" ? "/" : p + "/")
        }
    }
}

/// A folder of the menu with the folders inside it that have sessions too.
public struct FolderNode: Identifiable, Equatable, Sendable {
    public var id: String { folder.path }
    public var folder: FolderChoice
    /// Every folder below `folder`, at any depth, by path.
    public var subfolders: [FolderChoice]

    /// Sessions in the folder and all its subfolders.
    public var total: Int { subfolders.reduce(folder.sessions) { $0 + $1.sessions } }

    /// `.claude/worktrees/wool` for `/p/book/.claude/worktrees/wool` in `/p/book`.
    public func relativePath(of sub: FolderChoice) -> String {
        sub.path.hasPrefix(folder.path + "/") ? String(sub.path.dropFirst(folder.path.count + 1)) : sub.path
    }
}

public enum SessionList {
    /// Sessions active in `period`, in the `folder` scope (nil: any folder), whose
    /// title, prompts, project or id contain every word of `query` (any
    /// case), the newest first.
    public static func filter(_ sessions: [Session], query: String, period: Period, folder: FolderScope? = nil, now: Date,
                              calendar: Calendar = .current) -> [Session] {
        let start = period.start(now: now, calendar: calendar)
        let folder: FolderScope? = switch folder {
        case let .only(p)?: .only(normalized(p))
        case let .withSubfolders(p)?: .withSubfolders(normalized(p))
        case nil: nil
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return sessions
            .filter { s in
                // No model call and no longer running: a `claude -p /usage` run
                // or a session closed before its first answer.
                if s.usage.total == 0, !s.active { return false }
                if let start, s.lastActivity < start { return false }
                if let folder, !folder.contains(normalized(s.projectDir)) { return false }
                if words.isEmpty { return true }
                let text = [s.title, s.firstPrompt ?? "", s.lastPrompt ?? "", s.projectDir, s.gitBranch ?? "", s.id]
                    .joined(separator: "\n").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The folders with sessions in `period`, by label (any case). `keeping`
    /// (the folder chosen now) stays in the list with 0 sessions when the
    /// period has none, so the menu can still show it.
    public static func folders(_ sessions: [Session], period: Period, keeping: String? = nil, now: Date,
                               calendar: Calendar = .current) -> [FolderChoice] {
        var counts: [String: Int] = [:]
        for s in filter(sessions, query: "", period: period, now: now, calendar: calendar) {
            counts[normalized(s.projectDir), default: 0] += 1
        }
        if let keeping { counts[normalized(keeping), default: 0] += 0 }
        let labels = labels(for: Array(counts.keys))
        return counts
            .map { FolderChoice(path: $0.key, label: labels[$0.key] ?? $0.key, sessions: $0.value) }
            .sorted {
                let order = $0.label.localizedCaseInsensitiveCompare($1.label)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
            }
    }

    /// The choices whose label or path contain every word of `search` (any
    /// case), in the same order.
    public static func matching(_ choices: [FolderChoice], search: String) -> [FolderChoice] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        if words.isEmpty { return choices }
        return choices.filter { c in
            let text = (c.label + "\n" + c.path).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// The folders as a tree: each folder that is not inside another folder
    /// of the list, with all the folders inside it (at any depth, by path).
    public static func folderTree(_ choices: [FolderChoice]) -> [FolderNode] {
        let paths = Set(choices.map(\.path))
        func isInsideAnother(_ path: String) -> Bool {
            var p = (path as NSString).deletingLastPathComponent
            while p != "/" && !p.isEmpty {
                if paths.contains(p) { return true }
                p = (p as NSString).deletingLastPathComponent
            }
            return false
        }
        return choices.filter { !isInsideAnother($0.path) }.map { top in
            FolderNode(folder: top, subfolders: choices.filter { $0.path.hasPrefix(top.path + "/") }.sorted { $0.path < $1.path })
        }
    }

    /// The folders that match `search` (every word in the label or path), or
    /// that have a matching subfolder. A matching folder keeps all its
    /// subfolders; else only the matching ones stay.
    public static func matching(_ nodes: [FolderNode], search: String) -> [FolderNode] {
        if search.split(whereSeparator: \.isWhitespace).isEmpty { return nodes }
        return nodes.compactMap { node in
            if !matching([node.folder], search: search).isEmpty { return node }
            let subs = matching(node.subfolders, search: search)
            return subs.isEmpty ? nil : FolderNode(folder: node.folder, subfolders: subs)
        }
    }

    /// The last path part; the last two when the last is not unique; the
    /// whole path when those are not unique either.
    private static func labels(for paths: [String]) -> [String: String] {
        func tail(_ path: String, _ n: Int) -> String {
            let parts = path.split(separator: "/")
            return parts.isEmpty ? path : parts.suffix(n).joined(separator: "/")
        }
        var out: [String: String] = [:]
        for n in 1 ... 2 {
            let remaining = paths.filter { out[$0] == nil }
            let byLabel = Dictionary(grouping: remaining) { tail($0, n) }
            for (label, group) in byLabel where group.count == 1 { out[group[0]] = label }
        }
        for p in paths where out[p] == nil { out[p] = p }
        return out
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Sections by the day of the last activity: Today, Yesterday, then dates.
    public static func byDay(_ sessions: [Session], now: Date, calendar: Calendar = .current) -> [DaySection] {
        var out: [DaySection] = []
        for s in sessions {
            let title = dayTitle(s.lastActivity, now: now, calendar: calendar)
            if out.last?.title == title {
                out[out.count - 1].sessions.append(s)
                out[out.count - 1].usage = out[out.count - 1].usage + s.usage
            } else {
                out.append(DaySection(title: title, sessions: [s], usage: s.usage))
            }
        }
        return out
    }

    public static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let style = Date.FormatStyle(calendar: calendar).weekday(.wide).day().month(.wide).locale(Locale(identifier: "en_GB"))
        return date.formatted(style)
    }

    public static func total(_ sessions: [Session]) -> TokenUsage {
        sessions.reduce(TokenUsage()) { $0 + $1.usage }
    }

    /// Tokens of the sessions active today: the number next to the menu bar icon.
    public static func todayTotal(_ sessions: [Session], now: Date, calendar: Calendar = .current) -> UInt64 {
        total(filter(sessions, query: "", period: .today, now: now, calendar: calendar)).total
    }
}
