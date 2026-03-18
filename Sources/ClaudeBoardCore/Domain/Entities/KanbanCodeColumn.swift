import Foundation

/// The columns on the Kanban board, in display order.
public enum ClaudeBoardColumn: String, Codable, CaseIterable, Sendable {
    case backlog
    case inProgress = "in_progress"
    case waiting = "requires_attention"
    case done

    // Resilient decoding: unknown column values default to .done instead of failing
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ClaudeBoardColumn(rawValue: raw) ?? .done
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

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
