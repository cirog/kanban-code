import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("CardReconciler")
struct CardReconcilerTests {

    // MARK: - Slug-based matching

    @Test("Session with matching slug chains to existing card instead of creating new")
    func slugMatchChainsSession() {
        // Existing card has session with slug "test-slug"
        let existingLink = Link(
            id: "card-1",
            projectPath: "/test",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session-id",
                sessionPath: "/path/to/old-session.jsonl",
                slug: "test-slug"
            )
        )

        // New session has different ID but same slug
        var newSession = Session(id: "new-session-id")
        newSession.projectPath = "/test"
        newSession.jsonlPath = "/path/to/new-session.jsonl"
        newSession.slug = "test-slug"
        newSession.messageCount = 5
        newSession.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [newSession],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        // Should still be 1 card, not 2
        #expect(result.count == 1)

        let card = result.first!
        #expect(card.id == "card-1")

        // SessionLink should point to new session
        #expect(card.sessionLink?.sessionId == "new-session-id")
        #expect(card.sessionLink?.sessionPath == "/path/to/new-session.jsonl")

        // Old session path should be preserved in previousSessionPaths
        #expect(card.sessionLink?.previousSessionPaths == ["/path/to/old-session.jsonl"])
        #expect(card.sessionLink?.slug == "test-slug")
    }

    @Test("Session without slug still creates new card when unmatched")
    func noSlugCreatesNewCard() {
        let existingLink = Link(
            id: "card-1",
            projectPath: "/test",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session-id",
                sessionPath: "/path/to/old.jsonl"
            )
        )

        var newSession = Session(id: "new-session-id")
        newSession.projectPath = "/test"
        newSession.jsonlPath = "/path/to/new.jsonl"
        newSession.messageCount = 3
        newSession.modifiedTime = .now
        // No slug — should NOT match

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [newSession],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        // Should be 2 cards — no slug match
        #expect(result.count == 2)
    }

    @Test("Multiple context resets accumulate previousSessionPaths")
    func multipleChains() {
        // Card already has one previous session
        let existingLink = Link(
            id: "card-1",
            projectPath: "/test",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-2",
                sessionPath: "/path/to/session-2.jsonl",
                slug: "my-slug",
                previousSessionPaths: ["/path/to/session-1.jsonl"]
            )
        )

        // Third session with same slug
        var session3 = Session(id: "session-3")
        session3.projectPath = "/test"
        session3.jsonlPath = "/path/to/session-3.jsonl"
        session3.slug = "my-slug"
        session3.messageCount = 2
        session3.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session3],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        #expect(result.count == 1)
        let card = result.first!
        #expect(card.sessionLink?.sessionId == "session-3")
        #expect(card.sessionLink?.previousSessionPaths == [
            "/path/to/session-1.jsonl",
            "/path/to/session-2.jsonl",
        ])
    }

    @Test("Exact sessionId match takes priority over slug match")
    func sessionIdPriorityOverSlug() {
        // Two cards: one with exact sessionId, one with same slug
        let card1 = Link(
            id: "card-1",
            projectPath: "/test",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-A",
                sessionPath: "/path/to/A.jsonl",
                slug: "shared-slug"
            )
        )

        // Session A shows up again (same sessionId)
        var sessionA = Session(id: "session-A")
        sessionA.projectPath = "/test"
        sessionA.jsonlPath = "/path/to/A.jsonl"
        sessionA.slug = "shared-slug"
        sessionA.messageCount = 10
        sessionA.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [sessionA],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [card1], snapshot: snapshot)

        // Should match by sessionId, NOT chain
        #expect(result.count == 1)
        let card = result.first!
        #expect(card.sessionLink?.sessionId == "session-A")
        #expect(card.sessionLink?.previousSessionPaths == nil)
    }
}
