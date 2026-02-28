import Foundation

/// The columns on the Kanban board, in display order.
public enum KanbanColumn: String, Codable, CaseIterable, Sendable {
    case backlog
    case inProgress = "in_progress"
    case requiresAttention = "requires_attention"
    case inReview = "in_review"
    case done
    case allSessions = "all_sessions"

    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In Progress"
        case .requiresAttention: "Requires Attention"
        case .inReview: "In Review"
        case .done: "Done"
        case .allSessions: "All Sessions"
        }
    }
}
