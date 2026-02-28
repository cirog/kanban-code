import Foundation

/// Unified PR status with priority ordering (highest urgency first).
public enum PRStatus: String, Codable, Sendable, Comparable {
    case failing
    case unresolved
    case changesRequested = "changes_requested"
    case reviewNeeded = "review_needed"
    case pendingCI = "pending_ci"
    case approved
    case merged
    case closed

    /// Priority for ordering (lower = higher urgency).
    private var priority: Int {
        switch self {
        case .failing: 0
        case .unresolved: 1
        case .changesRequested: 2
        case .reviewNeeded: 3
        case .pendingCI: 4
        case .approved: 5
        case .merged: 6
        case .closed: 7
        }
    }

    public static func < (lhs: PRStatus, rhs: PRStatus) -> Bool {
        lhs.priority < rhs.priority
    }
}

/// CI check aggregation result.
public enum ChecksStatus: String, Codable, Sendable {
    case pass
    case fail
    case pending
    case none
}
