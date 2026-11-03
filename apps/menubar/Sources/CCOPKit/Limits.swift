// The limits Claude Code shows in `/usage`. `claude -p /usage` prints them
// as text (checked 2026-11-03, Claude Code 2.x):
//
//   Current week (all models): 97% used · resets Nov 3 at 7:59pm (Europe/London)
//   Current week (Fable): 0% used · resets Nov 3 at 8pm (Europe/London)
//
//   What's contributing to your usage?
//   Last 24h · 5581 requests · 39 sessions
//     73%  Give "general-purpose" subagents a cheaper model
//     Top skills: /a 2%, /b 1%
//
// It is not a stable format: `parse` returns nil when it finds no limit line,
// and the app then asks for the numbers by hand.

import Foundation

public struct UsageLimits: Codable, Equatable, Sendable {
    public struct Limit: Codable, Equatable, Sendable, Identifiable {
        /// "Current week", "Current session".
        public var label: String
        /// "all models", "Fable"; nil when the line has no parentheses.
        public var scope: String?
        public var usedPercent: Double
        public var resetsAt: Date?
        /// The reset as Claude Code wrote it: "Nov 3 at 7:59pm (Europe/London)".
        public var resetText: String?

        public var id: String { label + "|" + (scope ?? "") }

        /// "Week · all models", "Session".
        public var title: String {
            let head = label.hasPrefix("Current ") ? String(label.dropFirst(8)).capitalized : label
            return scope.map { "\(head) · \($0)" } ?? head
        }

        public init(label: String, scope: String? = nil, usedPercent: Double, resetsAt: Date? = nil, resetText: String? = nil) {
            self.label = label
            self.scope = scope
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.resetText = resetText
        }
    }

    public struct Tip: Codable, Equatable, Sendable, Identifiable {
        public var percent: Int
        public var text: String
        public var id: String { text }
    }

    /// One "Last 24h · 5581 requests · 39 sessions" block.
    public struct Period: Codable, Equatable, Sendable, Identifiable {
        /// "Last 24h", "Last 7d".
        public var title: String
        /// "5581 requests · 39 sessions".
        public var summary: String
        public var tips: [Tip]
        /// "Top skills: /a 2%, /b 1%" and the like.
        public var extras: [String]
        public var id: String { title }
    }

    public var subscription: Bool
    public var limits: [Limit]
    public var periods: [Period]
    public var readAt: Date

    /// The weekly limit for all models: "Current week (all models)", or a
    /// "Current week" line with no model.
    public var week: Limit? {
        limits.first { $0.label == "Current week" && ($0.scope == nil || $0.scope?.lowercased() == "all models") }
    }

    public static func parse(_ text: String, now: Date) -> UsageLimits? {
        var limits: [Limit] = []
        var periods: [Period] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let limit = parseLimit(line, now: now) {
                limits.append(limit)
            } else if line.hasPrefix("Last "), line.contains("·") {
                let parts = line.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                periods.append(Period(title: parts[0], summary: parts.dropFirst().joined(separator: " · "), tips: [], extras: []))
            } else if !periods.isEmpty, let tip = parseTip(line) {
                periods[periods.count - 1].tips.append(tip)
            } else if !periods.isEmpty, line.hasPrefix("Top "), line.contains(":") {
                periods[periods.count - 1].extras.append(line)
            }
        }
        guard !limits.isEmpty else { return nil }
        return UsageLimits(subscription: text.contains("subscription"), limits: limits, periods: periods, readAt: now)
    }

    /// `Current week (all models): 97% used · resets Nov 3 at 7:59pm (Europe/London)`.
    static func parseLimit(_ line: String, now: Date) -> Limit? {
        guard line.hasPrefix("Current "), let colon = line.firstIndex(of: ":") else { return nil }
        var head = String(line[..<colon])
        var scope: String?
        if let open = head.firstIndex(of: "("), head.hasSuffix(")") {
            scope = String(head[head.index(after: open) ..< head.index(before: head.endIndex)])
            head = String(head[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let percentEnd = rest.range(of: "% used") else { return nil }
        guard let percent = Double(rest[..<percentEnd.lowerBound].trimmingCharacters(in: .whitespaces)) else { return nil }
        var resetText: String?
        if let r = rest.range(of: "resets ") {
            resetText = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return Limit(label: head, scope: scope, usedPercent: percent,
                     resetsAt: resetText.flatMap { parseReset($0, now: now) }, resetText: resetText)
    }

    /// `  73%  Give "general-purpose" subagents a cheaper model`.
    static func parseTip(_ line: String) -> Tip? {
        guard let pct = line.firstIndex(of: "%"), let n = Int(line[..<pct]) else { return nil }
        let text = line[line.index(after: pct)...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Tip(percent: n, text: text)
    }

    /// `Nov 3 at 7:59pm (Europe/London)`, `8pm (Europe/London)`, `Nov 3 at 8pm`.
    /// A time with no date is the next such time; a date with no year is the
    /// nearest one that is not more than a day in the past.
    /// /usage shows a period's last minute ("7:59pm"): the reset is the
    /// minute after it (20:00). ccop sums costs by the hour, so a week that
    /// starts at 19:59 would take in the old week's whole 19:00 hour.
    static func parseReset(_ text: String, now: Date) -> Date? {
        var s = text
        var zone = TimeZone.current
        if let open = s.lastIndex(of: "("), s.hasSuffix(")") {
            let name = String(s[s.index(after: open) ..< s.index(before: s.endIndex)])
            if let z = TimeZone(identifier: name) { zone = z }
            s = String(s[..<open]).trimmingCharacters(in: .whitespaces)
        }
        var datePart: String?
        var timePart = s
        if let at = s.range(of: " at ") {
            datePart = String(s[..<at.lowerBound])
            timePart = String(s[at.upperBound...])
        } else if s.contains(" "), !s.lowercased().hasSuffix("am"), !s.lowercased().hasSuffix("pm") {
            datePart = s
            timePart = "12am"
        }
        guard let (hour, minute) = parseTime(timePart) else { return nil }
        let next: TimeInterval = minute == 59 ? 60 : 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        if let datePart {
            let words = datePart.split(separator: " ")
            guard words.count == 2, let month = monthNumber(String(words[0])), let day = Int(words[1]) else { return nil }
            let year = cal.component(.year, from: now)
            let dates = [year - 1, year, year + 1].compactMap {
                cal.date(from: DateComponents(year: $0, month: month, day: day, hour: hour, minute: minute))
            }
            return dates.filter { $0 > now.addingTimeInterval(-86400) }.min()?.addingTimeInterval(next)
        }
        return cal.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)?
            .addingTimeInterval(next)
    }

    /// `7:59pm`, `8pm`, `12am`, `19:59`.
    static func parseTime(_ text: String) -> (Int, Int)? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        var body = t
        var pm: Bool?
        if t.hasSuffix("pm") { pm = true; body = String(t.dropLast(2)) } else if t.hasSuffix("am") { pm = false; body = String(t.dropLast(2)) }
        let parts = body.split(separator: ":")
        guard let h = Int(parts.first ?? ""), parts.count <= 2 else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let m, (0 ..< 60).contains(m) else { return nil }
        var hour = h
        if let pm {
            guard (1 ... 12).contains(h) else { return nil }
            hour = h % 12 + (pm ? 12 : 0)
        }
        guard (0 ..< 24).contains(hour) else { return nil }
        return (hour, m)
    }

    static func monthNumber(_ word: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: String(word.lowercased().prefix(3))).map { $0 + 1 }
    }

    public static let defaultsKey = "usageLimits"

    public static func load(_ defaults: UserDefaults = .standard) -> UsageLimits? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(UsageLimits.self, from: $0) }
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

public enum LimitsReaderError: Error, LocalizedError, Equatable {
    case failed(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .failed(why): "Could not run claude -p /usage: \(why)"
        case let .unreadable(text): "claude -p /usage printed no limits: \(text.prefix(200))"
        }
    }
}

/// Runs `claude -p /usage` in the user's login shell, so `claude` is found
/// as in a terminal. It runs in the home folder, not in a project.
public enum LimitsReader {
    /// `--no-session-persistence`: without it each read leaves a "/usage"
    /// session (0 tokens: /usage calls no model) in ~/.claude/projects.
    public static let command = "claude -p --no-session-persistence /usage"

    public static func read(now: @autoclosure () -> Date = Date(), timeout: TimeInterval = 90) throws -> UsageLimits {
        let text = try run(timeout: timeout)
        guard let limits = UsageLimits.parse(text, now: now()) else {
            throw LimitsReaderError.unreadable(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return limits
    }

    static func run(timeout: TimeInterval) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw LimitsReaderError.failed(error.localizedDescription) }
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        deadline.cancel()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LimitsReaderError.failed(message.isEmpty ? "exit \(p.terminationStatus)" : message)
        }
        return text
    }
}
