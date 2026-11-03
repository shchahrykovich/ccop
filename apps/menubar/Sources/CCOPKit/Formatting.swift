import Foundation

public enum Format {
    /// A token count in a few characters: `812`, `46K`, `9.3M`, `1.2B`.
    /// The same rules as `short` in libs/core/src/usage.rs.
    public static func tokens(_ n: UInt64) -> String {
        let d = Double(n)
        switch n {
        case 0 ..< 1000: return String(n)
        case 1000 ..< 999_500: return "\(Int((d / 1e3).rounded()))K"
        case 999_500 ..< 9_950_000: return String(format: "%.1fM", d / 1e6)
        case 9_950_000 ..< 999_500_000: return "\(Int((d / 1e6).rounded()))M"
        default: return String(format: "%.1fB", d / 1e9)
        }
    }

    /// `96%`.
    public static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// `812 KB`, `3.4 MB`.
    public static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    /// `850 ms`, `12 s`, `4m 05s`, `1h 07m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        switch seconds {
        case ..<1: return "\(Int((max(0, seconds) * 1000).rounded())) ms"
        case ..<60: return "\(s) s"
        case ..<3600: return String(format: "%dm %02ds", s / 60, s % 60)
        default: return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
        }
    }

    /// `just now`, `5 min ago`, `3 h ago`, `yesterday 14:05`, `28 Oct 14:05`.
    public static func ago(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(secs / 3600)) h ago" }
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        let day = date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
        return "\(day) \(time)"
    }
}
