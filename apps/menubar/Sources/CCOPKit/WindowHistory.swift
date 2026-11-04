// The main window's Back and Forward: the places the user went to, as in a
// web browser.

import Foundation

public enum DetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview, spend, cause, chat, anatomy, context
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overview: "Overview"
        case .spend: "Spend"
        case .cause: "Cause"
        case .chat: "Chat"
        case .anatomy: "Anatomy"
        case .context: "Context"
        }
    }
}

/// What the main window shows. It keeps only what the tab shows: the Chat
/// tab's lane and event, the Cause tab's cause. So a value the current tab does
/// not show never makes a new step in the history.
public struct WindowPlace: Equatable, Sendable {
    public let session: String
    public let tab: DetailTab
    public let chatLane: String?
    public let chatEvent: Int?
    public let causeID: String?

    public init(session: String, tab: DetailTab, chatLane: String? = nil, chatEvent: Int? = nil, causeID: String? = nil) {
        self.session = session
        self.tab = tab
        self.chatLane = tab == .chat ? chatLane : nil
        self.chatEvent = tab == .chat ? chatEvent : nil
        self.causeID = tab == .cause ? causeID : nil
    }
}

/// The current place, the places before it and the places after it. Going to a
/// new place removes the places after the current one.
public struct WindowHistory: Equatable, Sendable {
    public private(set) var current: WindowPlace?
    private var earlier: [WindowPlace] = []
    private var later: [WindowPlace] = []
    /// The most places to keep before the current one.
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var canGoBack: Bool { !earlier.isEmpty }
    public var canGoForward: Bool { !later.isEmpty }

    /// Records a place the user went to. The place that is already current
    /// changes nothing, so showing a place from the history adds no step.
    public mutating func visit(_ place: WindowPlace) {
        guard place != current else { return }
        if let current { earlier.append(current) }
        if earlier.count > limit { earlier.removeFirst(earlier.count - limit) }
        later = []
        current = place
    }

    /// Moves one place back and returns it; nil at the start.
    public mutating func goBack() -> WindowPlace? {
        guard let place = earlier.popLast(), let current else { return nil }
        later.append(current)
        self.current = place
        return place
    }

    /// Moves one place forward and returns it; nil at the end.
    public mutating func goForward() -> WindowPlace? {
        guard let place = later.popLast(), let current else { return nil }
        earlier.append(current)
        self.current = place
        return place
    }
}
