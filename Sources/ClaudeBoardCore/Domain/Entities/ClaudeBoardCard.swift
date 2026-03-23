import Foundation

/// A card on the Kanban board, combining Link + Session data for display.
public struct ClaudeBoardCard: Identifiable, Sendable {
    public let id: String // link.id — stable across refreshes
    public let link: Link
    public let session: Session?
    public let activityState: ActivityState?
    /// True when an async operation is in progress on this card (terminal creating).
    public let isBusy: Bool

    public init(link: Link, session: Session? = nil, activityState: ActivityState? = nil, isBusy: Bool = false) {
        self.id = link.id
        self.link = link
        self.session = session
        self.activityState = activityState
        self.isBusy = isBusy
    }

    /// Whether Claude is confirmed actively working right now (not just waiting).
    public var isActivelyWorking: Bool {
        activityState == .activelyWorking
    }

    /// Whether to show a spinner on the card.
    public var showSpinner: Bool {
        isActivelyWorking || link.isLaunching == true || isBusy
    }

    /// Best display title: link name → session display title → link fallback chain.
    public var displayTitle: String {
        if let name = link.name, !name.isEmpty { return name }
        if let session { return session.displayTitle }
        return link.displayTitle
    }

    /// Relative time since last activity.
    public var relativeTime: String {
        let date = link.lastActivity ?? link.updatedAt
        return Self.formatRelativeTime(date)
    }

    /// The column this card is in.
    public var column: ClaudeBoardColumn { link.column }

    static func formatRelativeTime(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days)d ago" }
        return "\(days / 30)mo ago"
    }
}
