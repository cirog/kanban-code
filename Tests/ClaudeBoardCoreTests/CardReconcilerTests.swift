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
        #expect(result.links.count == 1)

        let card = result.links.first!
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
        #expect(result.links.count == 2)
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

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.sessionLink?.sessionId == "session-3")
        #expect(card.sessionLink?.previousSessionPaths == [
            "/path/to/session-1.jsonl",
            "/path/to/session-2.jsonl",
        ])
    }

    @Test("Multiple existing cards with same slug are merged into one")
    func slugMergesDuplicateCards() {
        // Three cards each have their own session but share the same slug
        // This happens when sessions were discovered in the same batch
        let card1 = Link(
            id: "card-1",
            projectPath: "/test",
            column: .done,
            lastActivity: Date(timeIntervalSince1970: 1000),
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-1",
                sessionPath: "/path/to/session-1.jsonl",
                slug: "cozy-moseying-pudding"
            )
        )
        let card2 = Link(
            id: "card-2",
            projectPath: "/test",
            column: .done,
            lastActivity: Date(timeIntervalSince1970: 2000),
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-2",
                sessionPath: "/path/to/session-2.jsonl",
                slug: "cozy-moseying-pudding"
            )
        )
        let card3 = Link(
            id: "card-3",
            projectPath: "/test",
            column: .inProgress,
            lastActivity: Date(timeIntervalSince1970: 3000),
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-3",
                sessionPath: "/path/to/session-3.jsonl",
                slug: "cozy-moseying-pudding"
            )
        )

        // All three sessions still show up in discovery
        var s1 = Session(id: "session-1"); s1.projectPath = "/test"
        s1.jsonlPath = "/path/to/session-1.jsonl"; s1.slug = "cozy-moseying-pudding"
        s1.messageCount = 5; s1.modifiedTime = Date(timeIntervalSince1970: 1000)
        var s2 = Session(id: "session-2"); s2.projectPath = "/test"
        s2.jsonlPath = "/path/to/session-2.jsonl"; s2.slug = "cozy-moseying-pudding"
        s2.messageCount = 5; s2.modifiedTime = Date(timeIntervalSince1970: 2000)
        var s3 = Session(id: "session-3"); s3.projectPath = "/test"
        s3.jsonlPath = "/path/to/session-3.jsonl"; s3.slug = "cozy-moseying-pudding"
        s3.messageCount = 5; s3.modifiedTime = Date(timeIntervalSince1970: 3000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [s1, s2, s3],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [card1, card2, card3], snapshot: snapshot)

        // Should merge into 1 card (the most recent one)
        #expect(result.links.count == 1)
        #expect(result.mergedAwayCardIds == Set(["card-1", "card-2"]))
        let survivor = result.links.first!
        #expect(survivor.id == "card-3") // newest activity
        #expect(survivor.sessionLink?.sessionId == "session-3")
        #expect(survivor.sessionLink?.slug == "cozy-moseying-pudding")

        // Previous sessions should be preserved
        let prevPaths = survivor.sessionLink?.previousSessionPaths ?? []
        #expect(prevPaths.contains("/path/to/session-1.jsonl"))
        #expect(prevPaths.contains("/path/to/session-2.jsonl"))
    }

    @Test("Slug merge preserves user customizations from survivor card")
    func slugMergePreservesCustomizations() {
        // Card with a user-set name should be the survivor even if not newest
        let card1 = Link(
            id: "card-1",
            name: "My Custom Name",
            projectPath: "/test",
            column: .inProgress,
            lastActivity: Date(timeIntervalSince1970: 1000),
            manualOverrides: ManualOverrides(name: true),
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-1",
                sessionPath: "/path/to/session-1.jsonl",
                slug: "shared-slug"
            )
        )
        let card2 = Link(
            id: "card-2",
            projectPath: "/test",
            column: .done,
            lastActivity: Date(timeIntervalSince1970: 2000),
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-2",
                sessionPath: "/path/to/session-2.jsonl",
                slug: "shared-slug"
            )
        )

        var s1 = Session(id: "session-1"); s1.projectPath = "/test"
        s1.jsonlPath = "/path/to/session-1.jsonl"; s1.slug = "shared-slug"
        s1.messageCount = 5; s1.modifiedTime = Date(timeIntervalSince1970: 1000)
        var s2 = Session(id: "session-2"); s2.projectPath = "/test"
        s2.jsonlPath = "/path/to/session-2.jsonl"; s2.slug = "shared-slug"
        s2.messageCount = 5; s2.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [s1, s2],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [card1, card2], snapshot: snapshot)

        #expect(result.links.count == 1)
        let survivor = result.links.first!
        // Card with manual name override should survive
        #expect(survivor.name == "My Custom Name")
        #expect(survivor.manualOverrides.name == true)
    }

    @Test("Slug merge skips archived cards")
    func slugMergeSkipsArchived() {
        let active = Link(
            id: "card-1",
            projectPath: "/test",
            column: .done,
            lastActivity: Date(timeIntervalSince1970: 1000),
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-1",
                sessionPath: "/path/to/session-1.jsonl",
                slug: "shared-slug"
            )
        )
        let archived = Link(
            id: "card-2",
            projectPath: "/test",
            column: .done,
            lastActivity: Date(timeIntervalSince1970: 2000),
            manuallyArchived: true,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-2",
                sessionPath: "/path/to/session-2.jsonl",
                slug: "shared-slug"
            )
        )

        var s1 = Session(id: "session-1"); s1.projectPath = "/test"
        s1.jsonlPath = "/path/to/session-1.jsonl"; s1.slug = "shared-slug"
        s1.messageCount = 5; s1.modifiedTime = Date(timeIntervalSince1970: 1000)
        var s2 = Session(id: "session-2"); s2.projectPath = "/test"
        s2.jsonlPath = "/path/to/session-2.jsonl"; s2.slug = "shared-slug"
        s2.messageCount = 5; s2.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [s1, s2],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [active, archived], snapshot: snapshot)

        // Should NOT merge — archived card is excluded
        #expect(result.links.count == 2)
        #expect(result.mergedAwayCardIds.isEmpty)
    }

    @Test("Repeated reconciliation does not duplicate previousSessionPaths")
    func noDuplicatePaths() {
        // Simulates the scenario where reconciliation runs repeatedly on a card
        // that was already merged — sessions match by slug each cycle
        let survivor = Link(
            id: "card-1",
            projectPath: "/test",
            column: .done,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-3",
                sessionPath: "/path/to/session-3.jsonl",
                slug: "repeated-slug",
                previousSessionPaths: ["/path/to/session-1.jsonl", "/path/to/session-2.jsonl"]
            )
        )

        // All three sessions show up again (as they do every cycle)
        var s1 = Session(id: "session-1"); s1.projectPath = "/test"
        s1.jsonlPath = "/path/to/session-1.jsonl"; s1.slug = "repeated-slug"
        s1.messageCount = 5; s1.modifiedTime = Date(timeIntervalSince1970: 1000)
        var s2 = Session(id: "session-2"); s2.projectPath = "/test"
        s2.jsonlPath = "/path/to/session-2.jsonl"; s2.slug = "repeated-slug"
        s2.messageCount = 5; s2.modifiedTime = Date(timeIntervalSince1970: 2000)
        var s3 = Session(id: "session-3"); s3.projectPath = "/test"
        s3.jsonlPath = "/path/to/session-3.jsonl"; s3.slug = "repeated-slug"
        s3.messageCount = 5; s3.modifiedTime = Date(timeIntervalSince1970: 3000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [s1, s2, s3],
            tmuxSessions: [],
            didScanTmux: false
        )

        // Run reconciliation twice to simulate repeated cycles
        let result1 = CardReconciler.reconcile(existing: [survivor], snapshot: snapshot)
        #expect(result1.links.count == 1)
        let after1 = result1.links.first!
        let paths1 = after1.sessionLink?.previousSessionPaths ?? []

        let result2 = CardReconciler.reconcile(existing: [after1], snapshot: snapshot)
        #expect(result2.links.count == 1)
        let after2 = result2.links.first!
        let paths2 = after2.sessionLink?.previousSessionPaths ?? []

        // Paths should be stable — no growth across cycles
        #expect(paths1.count == paths2.count, "previousSessionPaths grew from \(paths1.count) to \(paths2.count) across cycles")
        // Should have exactly 2 previous paths (session-1 and session-2), not session-3 (that's the current)
        #expect(paths2.count == 2)
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
        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.sessionLink?.sessionId == "session-A")
        #expect(card.sessionLink?.previousSessionPaths == nil)
    }
}
