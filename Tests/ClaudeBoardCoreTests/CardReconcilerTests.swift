import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("CardReconciler")
struct CardReconcilerTests {

    // MARK: - Session already linked (managed card)

    @Test("Session matching existing card by sessionId updates lastActivity")
    func sessionIdMatchUpdatesActivity() {
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
        session.jsonlPath = "/path/to/A-updated.jsonl"
        session.slug = "some-slug"
        session.messageCount = 10
        session.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(
            existing: [existingLink],
            snapshot: snapshot,
            ownedSessionIds: ["session-A"],
            sessionIdByCardId: ["card-1": "session-A"]
        )

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.id == "card-1")
        #expect(card.lastActivity == Date(timeIntervalSince1970: 2000))
        #expect(card.slug == "some-slug")
    }

    @Test("Managed card is not hijacked by stale session from same project")
    func managedCardNotHijacked() {
        // Managed card with tmux, no slug yet (hook hasn't fired)
        let managedCard = Link(
            id: "card-managed",
            name: "Clean",
            projectPath: "/Users/ciro",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-card_managed")
        )

        // Old stale session from same project path
        var staleSession = Session(id: "stale-session")
        staleSession.projectPath = "/Users/ciro"
        staleSession.jsonlPath = "/path/to/stale.jsonl"
        staleSession.slug = "old-conversation"
        staleSession.messageCount = 100
        staleSession.modifiedTime = Date(timeIntervalSince1970: 1000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [staleSession],
            tmuxSessions: [TmuxSession(name: "ciro-card_managed", path: "/Users/ciro", attached: false)],
            didScanTmux: true
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
    }

    // MARK: - Discovered card creation

    @Test("Unmatched session creates discovered card")
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
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.source == .discovered)
        #expect(card.slug == "brand-new")
        #expect(card.tmuxLink == nil)
        #expect(card.projectPath == "/test")
    }

    @Test("Archived card is not duplicated by its own session")
    func archivedCardNotDuplicated() {
        let archived = Link(
            id: "card-archived",
            projectPath: "/test",
            column: .done,
            manuallyArchived: true,
            source: .manual,
            slug: "sess-old"
        )

        var session = Session(id: "sess-old")
        session.projectPath = "/test"
        session.messageCount = 10
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(
            existing: [archived],
            snapshot: snapshot,
            ownedSessionIds: ["sess-old"],
            sessionIdByCardId: ["card-archived": "sess-old"]
        )

        #expect(result.links.count == 1)
        #expect(result.links.first!.id == "card-archived")
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
            tmuxSessions: [], // dead-tmux not in live list
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.links.first!.tmuxLink == nil)
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
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)

        #expect(result.links.first!.tmuxLink?.sessionName == "alive-tmux")
    }

    // MARK: - Mixed scenarios

    @Test("Multiple sessions: linked ones update, unlinked ones create discovered cards")
    func mixedLinkedAndUnlinked() {
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
        sess2.messageCount = 5
        sess2.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [sess1, sess2],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(
            existing: [managed],
            snapshot: snapshot,
            ownedSessionIds: ["sess-1"],
            sessionIdByCardId: ["card-managed": "sess-1"]
        )

        #expect(result.links.count == 2) // managed + 1 discovered
        let managedResult = result.links.first(where: { $0.id == "card-managed" })!
        #expect(managedResult.slug == "managed-slug")
        let discovered = result.links.first(where: { $0.id != "card-managed" })!
        #expect(discovered.source == .discovered)
    }

    @Test("Fills projectPath on card when session provides it")
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
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(
            existing: [link],
            snapshot: snapshot,
            ownedSessionIds: ["sess-1"],
            sessionIdByCardId: ["card-1": "sess-1"]
        )

        #expect(result.links.first!.projectPath == "/discovered/path")
    }
}
