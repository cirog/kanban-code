import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("CardReconciler")
struct CardReconcilerTests {

    // MARK: - Already owned (Step 1)

    @Test("Owned session is skipped — no association, no card created")
    func ownedSessionSkipped() {
        let existingLink = Link(
            id: "card-1",
            projectPath: "/test",
            column: .waiting,
            lastActivity: Date(timeIntervalSince1970: 1000),
            source: .manual,
            slug: "some-slug"
        )

        var session = Session(id: "session-A")
        session.projectPath = "/test"
        session.slug = "some-slug"
        session.messageCount = 10
        session.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false,
            ownedSessionIds: ["session-A"]
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.newAssociations.isEmpty)
        // lastActivity should NOT be updated — owned sessions are skipped entirely
        let card = result.links.first!
        #expect(card.id == "card-1")
        #expect(card.lastActivity == Date(timeIntervalSince1970: 1000))
    }

    // MARK: - Slug match (Step 2)

    @Test("Unowned session matching card by slug creates association and updates metadata")
    func slugMatchCreatesAssociation() {
        let existingLink = Link(
            id: "card-1",
            projectPath: nil,
            column: .waiting,
            lastActivity: Date(timeIntervalSince1970: 1000),
            source: .manual,
            slug: "my-slug"
        )

        var session = Session(id: "session-B")
        session.projectPath = "/discovered/path"
        session.jsonlPath = "/path/to/B.jsonl"
        session.slug = "my-slug"
        session.messageCount = 10
        session.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false,
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.id == "card-1")
        #expect(card.lastActivity == Date(timeIntervalSince1970: 2000))
        #expect(card.projectPath == "/discovered/path")

        #expect(result.newAssociations.count == 1)
        let assoc = result.newAssociations.first!
        #expect(assoc.sessionId == "session-B")
        #expect(assoc.cardId == "card-1")
        #expect(assoc.matchedBy == "slug")
        #expect(assoc.path == "/path/to/B.jsonl")
    }

    @Test("Slug match on archived card creates association but does not update metadata")
    func slugMatchOnArchivedCard() {
        let archived = Link(
            id: "card-archived",
            projectPath: "/old",
            column: .done,
            lastActivity: Date(timeIntervalSince1970: 500),
            manuallyArchived: true,
            source: .manual,
            slug: "archived-slug"
        )

        var session = Session(id: "sess-new")
        session.projectPath = "/new"
        session.jsonlPath = "/path/to/new.jsonl"
        session.slug = "archived-slug"
        session.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [archived], snapshot: snapshot)

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.lastActivity == Date(timeIntervalSince1970: 500)) // unchanged
        #expect(card.projectPath == "/old") // unchanged

        // Association is still created (for tracking)
        #expect(result.newAssociations.count == 1)
        #expect(result.newAssociations.first!.matchedBy == "slug")
    }

    // MARK: - Discovered card creation (Step 3)

    @Test("Unmatched session creates discovered card with association")
    func unmatchedSessionCreatesDiscoveredCard() {
        var session = Session(id: "new-session")
        session.projectPath = "/test"
        session.jsonlPath = "/path/to/new.jsonl"
        session.slug = "brand-new"
        session.messageCount = 5
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false,
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.source == .discovered)
        #expect(card.slug == "brand-new")
        #expect(card.tmuxLink == nil)
        #expect(card.projectPath == "/test")

        #expect(result.newAssociations.count == 1)
        let assoc = result.newAssociations.first!
        #expect(assoc.sessionId == "new-session")
        #expect(assoc.cardId == card.id)
        #expect(assoc.matchedBy == "discovered")
        #expect(assoc.path == "/path/to/new.jsonl")
    }

    @Test("Managed card is not hijacked by stale session from same project")
    func managedCardNotHijacked() {
        let managedCard = Link(
            id: "card-managed",
            name: "Clean",
            projectPath: "/Users/ciro",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-card_managed")
        )

        var staleSession = Session(id: "stale-session")
        staleSession.projectPath = "/Users/ciro"
        staleSession.jsonlPath = "/path/to/stale.jsonl"
        staleSession.slug = "old-conversation"
        staleSession.messageCount = 100
        staleSession.modifiedTime = Date(timeIntervalSince1970: 1000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [staleSession],
            tmuxSessions: [TmuxSession(name: "ciro-card_managed", path: "/Users/ciro", attached: false)],
            didScanTmux: true,
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [managedCard], snapshot: snapshot)

        // Managed card should NOT get the stale session
        let managed = result.links.first(where: { $0.id == "card-managed" })!
        #expect(managed.slug == nil)
        #expect(managed.tmuxLink != nil)

        // Stale session should become a separate discovered card
        #expect(result.links.count == 2)
        let discovered = result.links.first(where: { $0.id != "card-managed" })!
        #expect(discovered.slug == "old-conversation")
        #expect(discovered.source == .discovered)

        // Association created for the discovered card
        #expect(result.newAssociations.count == 1)
        #expect(result.newAssociations.first!.matchedBy == "discovered")
    }

    @Test("Multiple sessions with same slug: first one gets slug-matched, rest are owned or discovered")
    func multipleSameSlug() {
        let existingLink = Link(
            id: "card-1",
            column: .waiting,
            source: .manual,
            slug: "shared-slug"
        )

        var sess1 = Session(id: "sess-1")
        sess1.slug = "shared-slug"
        sess1.modifiedTime = .now

        var sess2 = Session(id: "sess-2")
        sess2.slug = "shared-slug"
        sess2.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [sess1, sess2],
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        // Both should create associations — first slug match, second also slug match (same card)
        #expect(result.newAssociations.count == 2)
        #expect(result.newAssociations.allSatisfy { $0.cardId == "card-1" })
        #expect(result.newAssociations.allSatisfy { $0.matchedBy == "slug" })
    }

    // MARK: - Dead tmux cleanup

    @Test("Dead tmux link is cleared")
    func deadTmuxCleared() {
        let link = Link(
            id: "card-1",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "dead-tmux")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [],
            tmuxSessions: [],
            didScanTmux: true,
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.links.first!.tmuxLink == nil)
        #expect(result.newAssociations.isEmpty)
    }

    @Test("Live tmux link is preserved")
    func liveTmuxPreserved() {
        let link = Link(
            id: "card-1",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "alive-tmux")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [],
            tmuxSessions: [TmuxSession(name: "alive-tmux", path: "/test", attached: false)],
            didScanTmux: true,
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)

        #expect(result.links.first!.tmuxLink?.sessionName == "alive-tmux")
    }

    // MARK: - Mixed scenarios

    @Test("Mixed: owned skipped, unmatched creates discovered card")
    func mixedOwnedAndUnmatched() {
        let managed = Link(
            id: "card-managed",
            projectPath: "/test",
            column: .inProgress,
            source: .manual,
            slug: "managed-slug"
        )

        var sess1 = Session(id: "sess-1")
        sess1.projectPath = "/test"
        sess1.messageCount = 10
        sess1.modifiedTime = .now

        var sess2 = Session(id: "sess-2")
        sess2.projectPath = "/test"
        sess2.jsonlPath = "/path/to/sess2.jsonl"
        sess2.messageCount = 5
        sess2.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [sess1, sess2],
            tmuxSessions: [],
            didScanTmux: false,
            ownedSessionIds: ["sess-1"]
        )

        let result = CardReconciler.reconcile(existing: [managed], snapshot: snapshot)

        #expect(result.links.count == 2) // managed + 1 discovered
        let managedResult = result.links.first(where: { $0.id == "card-managed" })!
        #expect(managedResult.slug == "managed-slug")
        let discovered = result.links.first(where: { $0.id != "card-managed" })!
        #expect(discovered.source == .discovered)

        // Only sess-2 creates an association (sess-1 is owned → skipped)
        #expect(result.newAssociations.count == 1)
        #expect(result.newAssociations.first!.sessionId == "sess-2")
        #expect(result.newAssociations.first!.matchedBy == "discovered")
    }

    @Test("Fills projectPath on card via slug match when session provides it")
    func fillsProjectPath() {
        let link = Link(
            id: "card-1",
            column: .waiting,
            source: .manual,
            slug: "sess-slug"
        )

        var session = Session(id: "sess-1")
        session.projectPath = "/discovered/path"
        session.slug = "sess-slug"
        session.jsonlPath = "/path/to/sess.jsonl"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false,
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)

        #expect(result.links.first!.projectPath == "/discovered/path")
        #expect(result.newAssociations.count == 1)
        #expect(result.newAssociations.first!.matchedBy == "slug")
    }

    @Test("Session with no slug and not owned creates discovered card")
    func noSlugCreatesDiscovered() {
        var session = Session(id: "no-slug-session")
        session.projectPath = "/test"
        session.jsonlPath = "/path.jsonl"
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            ownedSessionIds: []
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.links.first!.source == .discovered)
        #expect(result.newAssociations.count == 1)
        #expect(result.newAssociations.first!.matchedBy == "discovered")
    }
}
