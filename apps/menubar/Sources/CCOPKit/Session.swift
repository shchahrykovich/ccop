// The Swift copy of `ccop sessions --json` (libs/core/src/session.rs).
// api/sessions.example.json is decoded by SessionContractTests.

import Foundation

public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: UInt64
    public var cacheWriteTokens: UInt64
    /// The part of `cacheWriteTokens` written with the 1-hour TTL. The
    /// capital H: `convertFromSnakeCase` turns `cache_write_1h_tokens` into
    /// `cacheWrite1HTokens` ("1h".capitalized is "1H").
    public var cacheWrite1HTokens: UInt64
    public var cacheReadTokens: UInt64
    public var outputTokens: UInt64
    public var requests: UInt64

    public init(inputTokens: UInt64 = 0, cacheWriteTokens: UInt64 = 0, cacheWrite1HTokens: UInt64 = 0, cacheReadTokens: UInt64 = 0,
                outputTokens: UInt64 = 0, requests: UInt64 = 0) {
        self.inputTokens = inputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWrite1HTokens = cacheWrite1HTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.requests = requests
    }

    public var total: UInt64 { inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens }
    public var inputTotal: UInt64 { inputTokens + cacheWriteTokens + cacheReadTokens }

    /// The part of all input that came from the prompt cache, 0 to 1.
    public var cacheHitRatio: Double {
        inputTotal == 0 ? 0 : Double(cacheReadTokens) / Double(inputTotal)
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: a.inputTokens + b.inputTokens,
                   cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
                   cacheWrite1HTokens: a.cacheWrite1HTokens + b.cacheWrite1HTokens,
                   cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
                   outputTokens: a.outputTokens + b.outputTokens,
                   requests: a.requests + b.requests)
    }
}

public struct ModelUsage: Codable, Equatable, Sendable {
    public var model: String
    public var usage: TokenUsage
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var projectDir: String
    public var title: String
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var gitBranch: String?
    public var version: String?
    public var startedAt: Date?
    public var updatedAt: Date?
    public var modifiedAt: Date
    public var active: Bool
    public var prompts: UInt64
    public var subagents: UInt64
    public var usage: TokenUsage
    public var subagentUsage: TokenUsage
    /// API-equivalent cost of all calls, in millionths of a dollar.
    public var costMicros: UInt64
    public var models: [ModelUsage]
    public var transcript: String
    public var sizeBytes: UInt64
    public var continuedIn: String?

    /// The new model calls and typed prompts since an older copy of this session.
    public func changes(since old: Session) -> UInt64 {
        let now = usage.requests + prompts
        let then = old.usage.requests + old.prompts
        return now > then ? now - then : 0
    }

    /// When the session last did something.
    public var lastActivity: Date { updatedAt ?? modifiedAt }

    /// `shop` for `/Users/me/code/shop`.
    public var projectName: String {
        let trimmed = projectDir.hasSuffix("/") ? String(projectDir.dropLast()) : projectDir
        return trimmed.split(separator: "/").last.map(String.init) ?? projectDir
    }

    public static func decodeList(_ data: Data) throws -> [Session] {
        try makeDecoder().decode([Session].self, from: data)
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return d
    }
}

/// Made once: a list has thousands of dates, and making a parser per date
/// took seconds.
private let withFractions = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private let withoutFractions = Date.ISO8601FormatStyle()

/// RFC 3339 with 0 to 9 digits of fractions, as chrono writes it. Digits
/// after the third are cut: the parser reads milliseconds at most.
public func parseDate(_ text: String) -> Date? {
    guard let dot = text.firstIndex(of: ".") else { return try? withoutFractions.parse(text) }
    var s = text
    var end = s.index(after: dot)
    while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
    if s.distance(from: dot, to: end) > 4 {
        s.replaceSubrange(s.index(dot, offsetBy: 4) ..< end, with: "")
    }
    return try? withFractions.parse(s)
}
