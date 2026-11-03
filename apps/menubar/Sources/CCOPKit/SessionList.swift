// What the popover shows: sessions of a period that match a search, in
// day sections, with totals.

import Foundation

public enum Period: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all

    public var id: String { rawValue }

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

public enum SessionList {
    /// Sessions active in `period`, in `folder` (nil: any folder), whose
    /// title, prompts, project or id contain every word of `query` (any
    /// case), the newest first.
    public static func filter(_ sessions: [Session], query: String, period: Period, folder: String? = nil, now: Date,
                              calendar: Calendar = .current) -> [Session] {
        let start = period.start(now: now, calendar: calendar)
        let folder = folder.map(normalized)
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return sessions
            .filter { s in
                // No model call and no longer running: a `claude -p /usage` run
                // or a session closed before its first answer.
                if s.usage.total == 0, !s.active { return false }
                if let start, s.lastActivity < start { return false }
                if let folder, normalized(s.projectDir) != folder { return false }
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
