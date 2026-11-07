// What one call's context holds, as rows: the Swift copy of `contents` in
// libs/core/src/context.rs (`ccop context`).

import Foundation

public struct ContextRow: Equatable, Sendable, Identifiable {
    /// The part it counts in: `Tool: Read`, `Claude output`, `Start`.
    public var part: String
    /// The file, command, prompt or tool input; the part's name for `Start`,
    /// `Other` and Claude's answers together.
    public var label: String
    public var tokens: UInt64
    /// The events that put it there, largest first. Several when the same
    /// file was read again.
    public var events: [Int]

    public var id: String { "\(part)\u{1}\(label)\u{1}\(events.first ?? -1)" }
}

public enum ContextContents {
    /// The rows of call `call` (an index into `lane.context`), largest first.
    /// Grouped: one row per file, command or prompt, and one for all of
    /// Claude's answers. With `each`: one row per item. A path in the project
    /// folder `dir` is shown from that folder. A subagent's report is named
    /// by its lane's name in `names` (lane id → name).
    public static func rows(_ lane: AnatomyLane, call: Int, each: Bool, dir: String?, names: [String: String] = [:]) -> [ContextRow] {
        let items = lane.contextItems
            .filter { $0.firstCall <= call && call <= $0.lastCall }
            .enumerated()
            // Largest first; equal ones keep their order, as Rust's stable sort.
            .sorted { $0.element.tokens != $1.element.tokens ? $0.element.tokens > $1.element.tokens : $0.offset < $1.offset }
            .map(\.element)
        var rows: [ContextRow] = []
        var index: [String: Int] = [:]
        for item in items {
            let event = item.event.flatMap { lane.events.indices.contains($0) ? lane.events[$0] : nil }
            let label: String
            switch event {
            case let e? where e.kind == .answer && !each: label = item.part
            case let e? where e.kind == .report:
                let from = e.agentId ?? "another agent"
                let name = names[from] ?? "from \(from)"
                label = each ? e.text.map { oneLine("\(name): \($0)") } ?? name : name
            case let e?: label = e.text.map { text in oneLine(dir.map { inFolder(text, $0) } ?? text) } ?? item.part
            case nil: label = item.part
            }
            let key = "\(item.part)\u{1}\(label)"
            if !each, let i = index[key] {
                rows[i].tokens += item.tokens
                rows[i].events += item.event.map { [$0] } ?? []
            } else {
                index[key] = rows.count
                rows.append(ContextRow(part: item.part, label: label, tokens: item.tokens, events: item.event.map { [$0] } ?? []))
            }
        }
        return rows.enumerated()
            .sorted { $0.element.tokens != $1.element.tokens ? $0.element.tokens > $1.element.tokens : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The most rows any call of the lane has, so a list can keep its height
    /// while the pointer moves from call to call.
    public static func mostRows(_ lane: AnatomyLane, each: Bool, dir: String?, names: [String: String] = [:]) -> Int {
        lane.context.indices.map { rows(lane, call: $0, each: each, dir: dir, names: names).count }.max() ?? 0
    }

    /// The text of an `<agent-message from="ID">` (a background subagent's
    /// report) without its frame: what comes after "The report follows:",
    /// each line without the two spaces the frame puts before it. The text
    /// as it is when it is not such a message. As `agent_message` in anatomy.rs.
    public static func reportBody(_ text: String) -> String {
        guard let open = text.range(of: "<agent-message from=\""),
              let close = text[open.upperBound...].firstIndex(of: ">") else { return text }
        var body = text[text.index(after: close)...]
        if let end = body.range(of: "</agent-message>") { body = body[..<end.lowerBound] }
        if let r = body.range(of: "The report follows:") { body = body[r.upperBound...] }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("  ") ? $0.dropFirst(2) : $0 }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `path` from the folder `dir`, when it is in it: `/p/x/a.md` in `/p` →
    /// `x/a.md`. A path cut at the start (`…/p/x/a.md`) works too. Any other
    /// text stays as it is.
    public static func inFolder(_ path: String, _ dir: String) -> String {
        var d = dir
        while d.hasSuffix("/") { d.removeLast() }
        guard !d.isEmpty else { return path }
        let folder = d + "/"
        if path.hasPrefix(folder) { return String(path.dropFirst(folder.count)) }
        guard path.hasPrefix("…") else { return path }
        let cut = path.dropFirst()
        // The longest start of `cut` that ends with `/` and is an end of `dir/`.
        var best: String.Index?
        var i = cut.startIndex
        while i < cut.endIndex, cut.distance(from: cut.startIndex, to: i) <= folder.count {
            if cut[i] == "/", folder.hasSuffix(cut[...i]) { best = cut.index(after: i) }
            i = cut.index(after: i)
        }
        guard let best, best < cut.endIndex else { return path }
        return String(cut[best...])
    }

    /// Whitespace runs as one space, as `clip` in anatomy.rs.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
