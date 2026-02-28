import Testing
import Foundation
@testable import KanbanCore

@Suite("Notification Deduplication")
struct NotificationDedupTests {

    @Test("Stop + wait → should notify")
    func stopThenWait() async {
        let dedup = NotificationDeduplicator(dedupWindow: 0.1, stopDelay: 0.02)
        let _ = await dedup.recordStop(sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(30))
        let should = await dedup.shouldNotify(sessionId: "s1")
        #expect(should)
    }

    @Test("Stop + prompt → should NOT notify")
    func stopThenPrompt() async {
        let dedup = NotificationDeduplicator(dedupWindow: 0.1, stopDelay: 0.05)
        let _ = await dedup.recordStop(sessionId: "s1")
        await dedup.recordPrompt(sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(60))
        let should = await dedup.shouldNotify(sessionId: "s1")
        #expect(!should)
    }

    @Test("Dedup window prevents rapid notifications")
    func dedupWindow() async {
        let dedup = NotificationDeduplicator(dedupWindow: 0.5, stopDelay: 0.01)

        // First notification
        let _ = await dedup.recordStop(sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(20))
        let first = await dedup.shouldNotify(sessionId: "s1")
        #expect(first)

        // Second notification within window
        let _ = await dedup.recordStop(sessionId: "s1")
        try? await Task.sleep(for: .milliseconds(20))
        let second = await dedup.shouldNotify(sessionId: "s1")
        #expect(!second) // Should be deduped
    }

    @Test("Different sessions get independent dedup")
    func independentSessions() async {
        let dedup = NotificationDeduplicator(dedupWindow: 0.1, stopDelay: 0.01)

        let _ = await dedup.recordStop(sessionId: "s1")
        let _ = await dedup.recordStop(sessionId: "s2")
        try? await Task.sleep(for: .milliseconds(20))

        let s1 = await dedup.shouldNotify(sessionId: "s1")
        let s2 = await dedup.shouldNotify(sessionId: "s2")
        #expect(s1)
        #expect(s2)
    }

    @Test("Session numbers are sequential")
    func sessionNumbers() async {
        let dedup = NotificationDeduplicator()
        let n1 = await dedup.sessionNumber(for: "s1")
        let n2 = await dedup.sessionNumber(for: "s2")
        let n1again = await dedup.sessionNumber(for: "s1")

        #expect(n1 == 1)
        #expect(n2 == 2)
        #expect(n1again == 1) // Same session gets same number
    }

    @Test("Before delay → should NOT notify")
    func beforeDelay() async {
        let dedup = NotificationDeduplicator(dedupWindow: 10, stopDelay: 1.0)
        let _ = await dedup.recordStop(sessionId: "s1")
        // Check immediately (before delay)
        let should = await dedup.shouldNotify(sessionId: "s1")
        #expect(!should)
    }
}
