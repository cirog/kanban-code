import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("CardReconciler")
struct CardReconcilerTests {

    // MARK: - Carry-forward associations

    @Test("Existing associations are carried forward")
    func carryForward() {
        let card = Link(id: "card-1", column: .waiting, source: .manual,
                        tmuxLink: TmuxLink(sessionName: "ciro-card-1"))
        let existing = [
            CardReconciler.SessionAssociation(sessionId: "sess-old", cardId: "card-1",
                                               matchedBy: "tmux", path: "/old.jsonl")
        ]

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [], tmuxSessions: [], didScanTmux: false,
            hookEvents: [], existingAssociations: existing
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        #expect(result.associations.count == 1)
        #expect(result.associations[0].sessionId == "sess-old")
        #expect(result.associations[0].cardId == "card-1")
    }

    // MARK: - Tmux-based association

    @Test("Live tmux with SessionStart hook links session to card")
    func tmuxMatchLinks() {
        let card = Link(id: "card-1", column: .waiting, source: .manual,
                        tmuxLink: TmuxLink(sessionName: "ciro-card-1"))

        let hookEvent = HookEvent(sessionId: "sess-new", eventName: "SessionStart",
                                   transcriptPath: "/new.jsonl",
                                   tmuxSessionName: "ciro-card-1", timestamp: .now)

        var session = Session(id: "sess-new")
        session.projectPath = "/test"
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [TmuxSession(name: "ciro-card-1", path: "/test", attached: false)],
            didScanTmux: true,
            hookEvents: [hookEvent], existingAssociations: []
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        let assoc = result.associations.first(where: { $0.sessionId == "sess-new" })
        #expect(assoc != nil)
        #expect(assoc?.cardId == "card-1")
        #expect(assoc?.matchedBy == "tmux")
    }

    @Test("Multiple SessionStart in same tmux — latest wins")
    func latestSessionStartWins() {
        let card = Link(id: "card-1", column: .waiting, source: .manual,
                        tmuxLink: TmuxLink(sessionName: "ciro-card-1"))

        let old = HookEvent(sessionId: "sess-old", eventName: "SessionStart",
                             transcriptPath: "/old.jsonl", tmuxSessionName: "ciro-card-1",
                             timestamp: Date(timeIntervalSince1970: 1000))
        let new = HookEvent(sessionId: "sess-new", eventName: "SessionStart",
                             transcriptPath: "/new.jsonl", tmuxSessionName: "ciro-card-1",
                             timestamp: Date(timeIntervalSince1970: 2000))

        var sessOld = Session(id: "sess-old"); sessOld.modifiedTime = Date(timeIntervalSince1970: 1000)
        var sessNew = Session(id: "sess-new"); sessNew.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [sessOld, sessNew],
            tmuxSessions: [TmuxSession(name: "ciro-card-1", path: "/test", attached: false)],
            didScanTmux: true,
            hookEvents: [old, new], existingAssociations: []
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        // Both sessions should be associated to card-1
        let assocs = result.associations.filter { $0.cardId == "card-1" }
        #expect(assocs.count == 2)
        // sess-old should also be associated (it was in the same tmux)
        #expect(assocs.contains(where: { $0.sessionId == "sess-new" }))
        #expect(assocs.contains(where: { $0.sessionId == "sess-old" }))
    }

    // MARK: - Dead tmux carry-forward

    @Test("Card with dead tmux keeps previous association")
    func deadTmuxKeepsAssociation() {
        var card = Link(id: "card-1", column: .waiting, source: .manual,
                        tmuxLink: TmuxLink(sessionName: "dead-tmux"))
        let existing = [
            CardReconciler.SessionAssociation(sessionId: "sess-prev", cardId: "card-1",
                                               matchedBy: "tmux", path: "/prev.jsonl")
        ]

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [], tmuxSessions: [], // dead-tmux not in live list
            didScanTmux: true,
            hookEvents: [], existingAssociations: existing
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        // Association carried forward even though tmux is dead
        #expect(result.associations.contains(where: { $0.sessionId == "sess-prev" && $0.cardId == "card-1" }))
        // Tmux link cleared
        #expect(result.links.first(where: { $0.id == "card-1" })?.tmuxLink == nil)
    }

    // MARK: - Discovered card creation

    @Test("Unmatched session creates discovered card")
    func unmatchedCreatesDiscovered() {
        var session = Session(id: "orphan-sess")
        session.projectPath = "/test"
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session], tmuxSessions: [], didScanTmux: false,
            hookEvents: [], existingAssociations: []
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.source == .discovered)
        #expect(card.column == .done)
        let assoc = result.associations.first(where: { $0.sessionId == "orphan-sess" })
        #expect(assoc != nil)
        #expect(assoc?.cardId == card.id)
        #expect(assoc?.matchedBy == "discovered")
    }

    @Test("Already-owned session does not create discovered card")
    func ownedSessionNotDuplicated() {
        let card = Link(id: "card-1", column: .inProgress, source: .manual)
        let existing = [
            CardReconciler.SessionAssociation(sessionId: "sess-1", cardId: "card-1",
                                               matchedBy: "tmux", path: "/s.jsonl")
        ]

        var session = Session(id: "sess-1")
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session], tmuxSessions: [], didScanTmux: false,
            hookEvents: [], existingAssociations: existing
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        #expect(result.links.count == 1) // no discovered card created
        #expect(result.links.first!.id == "card-1")
    }

    // MARK: - Dead tmux cleanup

    @Test("Dead tmux link is cleared")
    func deadTmuxCleared() {
        let link = Link(id: "card-1", column: .waiting, source: .manual,
                        tmuxLink: TmuxLink(sessionName: "dead-tmux"))

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [], tmuxSessions: [],
            didScanTmux: true,
            hookEvents: [], existingAssociations: []
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)
        #expect(result.links.first!.tmuxLink == nil)
    }

    @Test("Live tmux link is preserved")
    func liveTmuxPreserved() {
        let link = Link(id: "card-1", column: .inProgress, source: .manual,
                        tmuxLink: TmuxLink(sessionName: "alive-tmux"))

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [],
            tmuxSessions: [TmuxSession(name: "alive-tmux", path: "/test", attached: false)],
            didScanTmux: true,
            hookEvents: [], existingAssociations: []
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)
        #expect(result.links.first!.tmuxLink?.sessionName == "alive-tmux")
    }
}
