import Foundation

/// The columns on the Kanban board, in display order.
public enum ClaudeBoardColumn: String, Codable, CaseIterable, Sendable {
    case backlog
    case inProgress = "in_progress"
    case waiting = "requires_attention"
    case done

    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In Progress"
        case .waiting: "Waiting"
        case .done: "Done"
        }
    }

    public var allowsBoardTaskCreation: Bool { true }
}
