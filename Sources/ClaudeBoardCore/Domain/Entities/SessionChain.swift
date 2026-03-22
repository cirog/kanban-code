import Foundation

/// Reason for a session transition in a chain. Best-effort detection.
public enum TransitionReason: Sendable, Equatable {
    case initial                        // first session in chain
    case resumed(gap: TimeInterval)     // same slug as previous
    case interrupted(gap: TimeInterval) // previous ended with Ctrl+C
    case newSession(gap: TimeInterval)  // fallback

    /// Human-readable label for display.
    public var label: String {
        switch self {
        case .initial: "Started"
        case .resumed: "Resumed"
        case .interrupted: "Interrupted"
        case .newSession: "New session"
        }
    }

    /// Formatted gap duration, e.g. "2h 15m gap". Nil for .initial.
    public var gapDescription: String? {
        let gap: TimeInterval
        switch self {
        case .initial: return nil
        case .resumed(let g): gap = g
        case .interrupted(let g): gap = g
        case .newSession(let g): gap = g
        }

        let totalMinutes = Int(gap) / 60
        if totalMinutes < 1 { return "<1m gap" }

        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 && days == 0 { parts.append("\(minutes)m") }

        return parts.joined(separator: " ") + " gap"
    }
}

/// One session in a card's chain, with timing and transition metadata.
public struct ChainSegment: Sendable, Identifiable {
    public let id: String              // sessionId
    public let path: String            // JSONL file path
    public let matchedBy: String       // "tmux" or "discovered"
    public let firstTimestamp: Date     // ordering key
    public let lastTimestamp: Date?     // for gap to next session
    public let slug: String?           // for resume detection
    public let transitionReason: TransitionReason

    public init(
        id: String, path: String, matchedBy: String,
        firstTimestamp: Date, lastTimestamp: Date?, slug: String?,
        transitionReason: TransitionReason
    ) {
        self.id = id
        self.path = path
        self.matchedBy = matchedBy
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.slug = slug
        self.transitionReason = transitionReason
    }
}

/// Ordered chain of sessions belonging to a single card.
public struct SessionChain: Sendable {
    public let cardId: String
    public let segments: [ChainSegment] // sorted oldest → newest
    public let totalSegments: Int       // may be > segments.count if paginated

    public init(cardId: String, segments: [ChainSegment], totalSegments: Int) {
        self.cardId = cardId
        self.segments = segments
        self.totalSegments = totalSegments
    }

    /// Whether more segments exist beyond what's loaded.
    public var hasMore: Bool { totalSegments > segments.count }
}
