import Foundation

/// Pure function: transforms raw DB rows + JSONL metadata into an ordered SessionChain.
public enum SessionChainBuilder {

    /// Raw segment data before transition detection (from DB + JSONL parsing).
    public struct RawSegment: Sendable {
        public let sessionId: String
        public let path: String
        public let matchedBy: String
        public let slug: String?
        public let firstTimestamp: Date
        public let lastTimestamp: Date
        public let lastLineText: String?

        public init(
            sessionId: String, path: String, matchedBy: String, slug: String?,
            firstTimestamp: Date, lastTimestamp: Date, lastLineText: String?
        ) {
            self.sessionId = sessionId
            self.path = path
            self.matchedBy = matchedBy
            self.slug = slug
            self.firstTimestamp = firstTimestamp
            self.lastTimestamp = lastTimestamp
            self.lastLineText = lastLineText
        }
    }

    /// Build a SessionChain from raw segments. Sorts by firstTimestamp, detects transitions.
    public static func build(cardId: String, rawSegments: [RawSegment], totalCount: Int) -> SessionChain {
        let sorted = rawSegments.sorted { $0.firstTimestamp < $1.firstTimestamp }

        var segments: [ChainSegment] = []
        for (i, raw) in sorted.enumerated() {
            let reason: TransitionReason
            if i == 0 {
                reason = .initial
            } else {
                let prev = sorted[i - 1]
                let gap = raw.firstTimestamp.timeIntervalSince(prev.lastTimestamp)
                reason = detectTransition(current: raw, previous: prev, gap: gap)
            }

            segments.append(ChainSegment(
                id: raw.sessionId, path: raw.path, matchedBy: raw.matchedBy,
                firstTimestamp: raw.firstTimestamp, lastTimestamp: raw.lastTimestamp,
                slug: raw.slug, transitionReason: reason
            ))
        }

        return SessionChain(cardId: cardId, segments: segments, totalSegments: totalCount)
    }

    /// Best-effort transition reason detection.
    private static func detectTransition(current: RawSegment, previous: RawSegment, gap: TimeInterval) -> TransitionReason {
        if let currentSlug = current.slug, let prevSlug = previous.slug,
           currentSlug == prevSlug, !currentSlug.isEmpty {
            return .resumed(gap: gap)
        }

        if let lastLine = previous.lastLineText,
           lastLine.contains("[Request interrupted by user]") {
            return .interrupted(gap: gap)
        }

        return .newSession(gap: gap)
    }
}
