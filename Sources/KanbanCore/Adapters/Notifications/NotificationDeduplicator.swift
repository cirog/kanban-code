import Foundation

/// Anti-duplicate logic for notifications.
/// Implements: 1s delay after Stop (skip if UserPromptSubmit arrives),
/// 62s dedup window per session, session numbering.
public actor NotificationDeduplicator {
    /// Per-session last notification time.
    private var lastNotified: [String: Date] = [:]
    /// Per-session pending stop times.
    private var pendingStops: [String: Date] = [:]
    /// Session number assignments.
    private var sessionNumbers: [String: Int] = [:]
    /// Next session number.
    private var nextNumber: Int = 1
    /// Dedup window in seconds.
    private let dedupWindow: TimeInterval
    /// Stop delay in seconds.
    private let stopDelay: TimeInterval
    /// Session number expiry in seconds.
    private let numberExpiry: TimeInterval

    public init(
        dedupWindow: TimeInterval = 62,
        stopDelay: TimeInterval = 1.0,
        numberExpiry: TimeInterval = 10800 // 3 hours
    ) {
        self.dedupWindow = dedupWindow
        self.stopDelay = stopDelay
        self.numberExpiry = numberExpiry
    }

    /// Record a Stop event. Returns true if notification should be sent after delay.
    public func recordStop(sessionId: String) -> Bool {
        pendingStops[sessionId] = Date()
        return true
    }

    /// Record a UserPromptSubmit. Cancels any pending stop notification.
    public func recordPrompt(sessionId: String) {
        pendingStops.removeValue(forKey: sessionId)
    }

    /// Check if a pending stop should now fire a notification.
    /// Call after stopDelay has elapsed.
    public func shouldNotify(sessionId: String) -> Bool {
        guard let stopTime = pendingStops[sessionId] else { return false }

        // Check if still pending (not cancelled by a new prompt)
        let elapsed = Date.now.timeIntervalSince(stopTime)
        guard elapsed >= stopDelay else { return false }

        // Check dedup window
        if let lastTime = lastNotified[sessionId] {
            let sinceLast = Date.now.timeIntervalSince(lastTime)
            if sinceLast < dedupWindow { return false }
        }

        // Clear pending and record notification
        pendingStops.removeValue(forKey: sessionId)
        lastNotified[sessionId] = Date()
        return true
    }

    /// Get or assign a session number.
    public func sessionNumber(for sessionId: String) -> Int {
        if let existing = sessionNumbers[sessionId] {
            return existing
        }
        let number = nextNumber
        nextNumber += 1
        sessionNumbers[sessionId] = number
        return number
    }

    /// Recycle expired session numbers (call periodically).
    public func recycleExpiredNumbers(activeSessions: Set<String>) {
        let now = Date()
        for (sessionId, _) in sessionNumbers {
            guard !activeSessions.contains(sessionId) else { continue }
            if let lastTime = lastNotified[sessionId],
               now.timeIntervalSince(lastTime) > numberExpiry {
                sessionNumbers.removeValue(forKey: sessionId)
            }
        }
    }
}
