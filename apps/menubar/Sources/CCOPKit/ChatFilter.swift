import Foundation

/// Which messages of a lane the Chat tab shows. Kinds are joined with "or";
/// `topCosts` then keeps only the most expensive 10% of what the kinds let
/// through (of every message with a cost when no kind is on).
public struct ChatFilter: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case user, bash, edit, write, agent

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .user: "User"
            case .bash: "Bash"
            case .edit: "Edit"
            case .write: "Write"
            case .agent: "Agent"
            }
        }

        func matches(_ e: AnatomyEvent) -> Bool {
            switch self {
            case .user: e.kind == .prompt
            case .bash: e.kind == .tool && e.tool == "Bash"
            case .edit: e.kind == .tool && ["Edit", "MultiEdit", "NotebookEdit"].contains(e.tool ?? "")
            case .write: e.kind == .tool && e.tool == "Write"
            case .agent: e.kind == .tool && ["Agent", "Task"].contains(e.tool ?? "")
            }
        }
    }

    /// The part of the messages `topCosts` keeps.
    public static let topShare = 0.1

    public var kinds: Set<Kind>
    public var topCosts: Bool

    public init(kinds: Set<Kind> = [], topCosts: Bool = false) {
        self.kinds = kinds
        self.topCosts = topCosts
    }

    public var isOn: Bool { !kinds.isEmpty || topCosts }

    /// The indices of the events to show, in their order.
    /// This filter when it shows event `index`; else no filter, so that going
    /// to that event finds it.
    public func showing(_ index: Int, in events: [AnatomyEvent]) -> ChatFilter {
        indices(events).contains(index) ? self : ChatFilter()
    }

    public func indices(_ events: [AnatomyEvent]) -> [Int] {
        var shown = events.indices.filter { i in kinds.isEmpty || kinds.contains { $0.matches(events[i]) } }
        if topCosts {
            shown = shown.filter { (events[$0].costMicros ?? 0) > 0 }
            let costs = shown.map { events[$0].costMicros ?? 0 }.sorted(by: >)
            guard !costs.isEmpty else { return [] }
            let keep = Int((Double(costs.count) * Self.topShare).rounded(.up))
            let line = costs[keep - 1]
            shown = shown.filter { (events[$0].costMicros ?? 0) >= line }
        }
        return shown
    }
}
