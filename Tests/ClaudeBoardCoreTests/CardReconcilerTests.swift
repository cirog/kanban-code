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

    // MARK: - Tmux fallback matching

    @Test("Session with different slug in same project creates separate card (no tmux swallowing)")
    func differentSlugCreatesSeparateCard() {
        // Existing card has a session with slug "old-slug" and a live tmux session
        let existingLink = Link(
            id: "card-1",
            projectPath: "/test",
            column: .inProgress,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session-id",
                sessionPath: "/path/to/old-session.jsonl",
                slug: "old-slug"
            ),
            tmuxLink: TmuxLink(sessionName: "claude-test-tmux")
        )

        // New session has DIFFERENT slug but same project path
        var newSession = Session(id: "new-session-id")
        newSession.projectPath = "/test"
        newSession.jsonlPath = "/path/to/new-session.jsonl"
        newSession.slug = "different-slug"
        newSession.messageCount = 5
        newSession.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [newSession],
            tmuxSessions: [TmuxSession(name: "claude-test-tmux", path: "/test", attached: false)],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        // Should be 2 cards — different slugs = different conversations
        #expect(result.links.count == 2)

        // Original card keeps its session
        let original = result.links.first { $0.id == "card-1" }!
        #expect(original.sessionLink?.sessionId == "old-session-id")
    }

    @Test("Session with no slug in same project creates separate card (no tmux swallowing)")
    func noSlugCreatesSeparateCard() {
        // Existing card has a live tmux session
        let existingLink = Link(
            id: "card-1",
            projectPath: "/test",
            column: .inProgress,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session-id",
                sessionPath: "/path/to/old.jsonl",
                slug: "old-slug"
            ),
            tmuxLink: TmuxLink(sessionName: "claude-tmux")
        )

        // New session has NO slug — should NOT be swallowed
        var newSession = Session(id: "new-session-id")
        newSession.projectPath = "/test"
        newSession.jsonlPath = "/path/to/new.jsonl"
        newSession.slug = nil
        newSession.messageCount = 3
        newSession.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [newSession],
            tmuxSessions: [TmuxSession(name: "claude-tmux", path: "/test", attached: false)],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        // Should be 2 cards — no slug means genuinely new session
        #expect(result.links.count == 2)
    }

    // MARK: - Slug-based dedup (post-matching)

    @Test("Duplicate cards with same slug are merged after initial slug-race creates orphan")
    func slugRaceDedupMergesDuplicates() {
        // Simulates the race condition:
        // Pass 1: new session discovered with slug=nil → created Card B
        // Pass 2: both cards now have the same slug but sessionId match keeps them separate
        //
        // Card A: the original card (has tmuxLink, older)
        // Card B: the orphan created during the slug race (no tmuxLink, newer)

        let cardA = Link(
            id: "card-A",
            projectPath: "/test",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session",
                sessionPath: "/path/to/old.jsonl",
                slug: "my-slug"
            ),
            tmuxLink: TmuxLink(sessionName: "kb-test")
        )

        let cardB = Link(
            id: "card-B",
            projectPath: "/test",
            column: .done,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "new-session",
                sessionPath: "/path/to/new.jsonl",
                slug: "my-slug"  // Same slug — these are the same conversation
            )
        )

        // Both sessions show up in discovery
        var sOld = Session(id: "old-session")
        sOld.projectPath = "/test"
        sOld.jsonlPath = "/path/to/old.jsonl"
        sOld.slug = "my-slug"
        sOld.messageCount = 20
        sOld.modifiedTime = Date(timeIntervalSince1970: 1000)

        var sNew = Session(id: "new-session")
        sNew.projectPath = "/test"
        sNew.jsonlPath = "/path/to/new.jsonl"
        sNew.slug = "my-slug"
        sNew.messageCount = 5
        sNew.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [sOld, sNew],
            tmuxSessions: [TmuxSession(name: "kb-test", path: "/test", attached: false)],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [cardA, cardB], snapshot: snapshot)

        // Should be 1 card — duplicates merged
        #expect(result.links.count == 1, "Expected 1 card after slug dedup, got \(result.links.count)")

        let survivor = result.links.first!
        // The card with tmuxLink should survive (Card A)
        #expect(survivor.id == "card-A")
        // Survivor should have the NEWEST session
        #expect(survivor.sessionLink?.sessionId == "new-session")
        #expect(survivor.sessionLink?.slug == "my-slug")
        // Old session path should be in previousSessionPaths
        #expect(survivor.sessionLink?.previousSessionPaths?.contains("/path/to/old.jsonl") == true)
    }

    @Test("Slug dedup prefers card with tmuxLink over discovered-only card")
    func slugDedupPrefersTmuxCard() {
        // Card A: discovered (no tmux)
        let cardA = Link(
            id: "card-A",
            projectPath: "/test",
            column: .done,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-1",
                sessionPath: "/path/to/s1.jsonl",
                slug: "shared-slug"
            )
        )

        // Card B: has tmux (should win even though created later)
        let cardB = Link(
            id: "card-B",
            projectPath: "/test",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "session-2",
                sessionPath: "/path/to/s2.jsonl",
                slug: "shared-slug"
            ),
            tmuxLink: TmuxLink(sessionName: "kb-test")
        )

        var s1 = Session(id: "session-1")
        s1.projectPath = "/test"; s1.jsonlPath = "/path/to/s1.jsonl"
        s1.slug = "shared-slug"; s1.messageCount = 10
        s1.modifiedTime = Date(timeIntervalSince1970: 1000)

        var s2 = Session(id: "session-2")
        s2.projectPath = "/test"; s2.jsonlPath = "/path/to/s2.jsonl"
        s2.slug = "shared-slug"; s2.messageCount = 5
        s2.modifiedTime = Date(timeIntervalSince1970: 2000)

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [s1, s2],
            tmuxSessions: [TmuxSession(name: "kb-test", path: "/test", attached: false)],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [cardA, cardB], snapshot: snapshot)

        #expect(result.links.count == 1)
        let survivor = result.links.first!
        // Card B (has tmux) should survive
        #expect(survivor.id == "card-B")
        #expect(survivor.tmuxLink != nil)
    }

    @Test("Slug dedup does not merge cards mid-launch")
    func slugDedupSkipsLaunchingCards() {
        var cardA = Link(
            id: "card-A",
            projectPath: "/test",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(
                sessionId: "old-session",
                slug: "shared-slug"
            ),
            tmuxLink: TmuxLink(sessionName: "kb-test")
        )
        cardA.isLaunching = true

        let cardB = Link(
            id: "card-B",
            projectPath: "/test",
            column: .done,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "new-session",
                slug: "shared-slug"
            )
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [cardA, cardB], snapshot: snapshot)

        // Should keep both — don't merge mid-launch
        #expect(result.links.count == 2)
    }

    // MARK: - Name-to-slug matching (step 3.5)

    @Test("Manual TASK card matched to session by name-to-slug")
    func nameToSlugMatch() {
        // Manual card with name "sync meetings", no session/tmux/prompt
        let taskCard = Link(
            id: "task-1",
            name: "sync meetings",
            column: .backlog,
            source: .manual
        )

        // Discovered session with slug "sync-meetings"
        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro"
        session.jsonlPath = "/path/to/session-1.jsonl"
        session.slug = "sync-meetings"
        session.messageCount = 5
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        // Should link session to existing TASK card, not create a new one
        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.id == "task-1")
        #expect(card.sessionLink?.sessionId == "session-1")
    }

    @Test("Name-to-slug normalizes casing and punctuation")
    func nameToSlugNormalization() {
        let taskCard = Link(
            id: "task-1",
            name: "Sync Meetings!",
            column: .backlog,
            source: .manual
        )

        var session = Session(id: "session-1")
        session.slug = "sync-meetings"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.links.first?.id == "task-1")
        #expect(result.links.first?.sessionLink?.sessionId == "session-1")
    }

    @Test("Name-to-slug does not match when slugs differ")
    func nameToSlugNoFalsePositive() {
        let taskCard = Link(
            id: "task-1",
            name: "sync meetings",
            column: .backlog,
            source: .manual
        )

        var session = Session(id: "session-1")
        session.slug = "claudeboard-reconciler-fix"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        // Should create a new card — slugs don't match
        #expect(result.links.count == 2)
    }

    @Test("Name-to-slug skips cards that already have a sessionLink")
    func nameToSlugSkipsLinkedCards() {
        let taskCard = Link(
            id: "task-1",
            name: "sync meetings",
            column: .waiting,
            source: .manual,
            sessionLink: SessionLink(sessionId: "existing-session")
        )

        var session = Session(id: "new-session")
        session.slug = "sync-meetings"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        // Should create new card — existing card already has a session
        #expect(result.links.count == 2)
    }

    @Test("Name-to-slug works for todoist cards too")
    func nameToSlugTodoist() {
        let todoistCard = Link(
            id: "todoist-1",
            name: "review PRs",
            column: .backlog,
            source: .todoist,
            todoistId: "123"
        )

        var session = Session(id: "session-1")
        session.slug = "review-prs"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [todoistCard], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.links.first?.id == "todoist-1")
    }

    @Test("Name-to-slug skips discovered cards (only manual/todoist)")
    func nameToSlugSkipsDiscovered() {
        let discoveredCard = Link(
            id: "disc-1",
            name: "sync meetings",
            column: .done,
            source: .discovered
        )

        var session = Session(id: "session-1")
        session.slug = "sync-meetings"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [discoveredCard], snapshot: snapshot)

        // Should create new card — discovered cards don't use name matching
        #expect(result.links.count == 2)
    }

    // MARK: - Solo project-path matching (step 3.6)

    @Test("Solo manual card matched by project path when only one exists")
    func soloProjectPathMatch() {
        let taskCard = Link(
            id: "task-1",
            name: "do stuff",
            projectPath: "/Users/ciro/myproject",
            column: .backlog,
            source: .manual
        )

        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro/myproject"
        session.slug = "completely-different-slug"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.links.first?.id == "task-1")
        #expect(result.links.first?.sessionLink?.sessionId == "session-1")
    }

    @Test("Ambiguous project path does not match when multiple manual cards exist")
    func ambiguousProjectPathNoMatch() {
        let task1 = Link(
            id: "task-1",
            name: "task A",
            projectPath: "/Users/ciro/myproject",
            column: .backlog,
            source: .manual
        )
        let task2 = Link(
            id: "task-2",
            name: "task B",
            projectPath: "/Users/ciro/myproject",
            column: .backlog,
            source: .manual
        )

        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro/myproject"
        session.slug = "something-unrelated"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [task1, task2], snapshot: snapshot)

        // Should create new card — ambiguous, can't pick between task-1 and task-2
        #expect(result.links.count == 3)
    }

    @Test("Solo project match skips cards with tmuxLink")
    func soloProjectSkipsTmuxCards() {
        // Card has a tmux session already — step 2 (projectPath+tmux) should handle it, not step 3.6
        let taskCard = Link(
            id: "task-1",
            name: "do stuff",
            projectPath: "/Users/ciro/myproject",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "test-tmux")
        )

        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro/myproject"
        session.slug = "different-slug"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [TmuxSession(name: "test-tmux", path: "/Users/ciro/myproject", attached: false)],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        // Step 2 (projectPath+tmux) should match, not step 3.6
        #expect(result.links.count == 1)
        #expect(result.links.first?.id == "task-1")
    }

    @Test("Solo project match requires matching projectPath")
    func soloProjectDifferentPath() {
        let taskCard = Link(
            id: "task-1",
            name: "do stuff",
            projectPath: "/Users/ciro/project-a",
            column: .backlog,
            source: .manual
        )

        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro/project-b"
        session.slug = "different-slug"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [],
            didScanTmux: false
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        // Different project paths — no match
        #expect(result.links.count == 2)
    }

    // MARK: - Step 2: projectPath+tmux matching with nil projectPath

    @Test("Step 2 matches name-only TASK card (nil projectPath) via tmux when solo candidate")
    func step2NilProjectPathSoloTmux() {
        // Name-only TASK card: has tmuxLink, no sessionLink, nil projectPath
        let taskCard = Link(
            id: "task-cb",
            name: "CB",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-task-cb")
        )

        var session = Session(id: "session-899fc")
        session.projectPath = "/Users/ciro"
        session.slug = "imperative-coalescing-hearth"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [TmuxSession(name: "ciro-task-cb", path: "/Users/ciro", attached: false)],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        // Should match — solo candidate with tmuxLink whose tmux path matches session projectPath
        #expect(result.links.count == 1)
        #expect(result.links.first?.id == "task-cb")
        #expect(result.links.first?.sessionLink?.sessionId == "session-899fc")
    }

    @Test("Step 2 does not match when two tmux cards share same projectPath (ambiguous)")
    func step2AmbiguousTmuxCards() {
        // Two name-only TASK cards, both with tmuxLink, no sessionLink, nil projectPath
        let card1 = Link(
            id: "task-cb",
            name: "CB",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-task-cb")
        )
        let card2 = Link(
            id: "task-sync",
            name: "sync meetings",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-task-sync")
        )

        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro"
        session.slug = "some-slug"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [
                TmuxSession(name: "ciro-task-cb", path: "/Users/ciro", attached: false),
                TmuxSession(name: "ciro-task-sync", path: "/Users/ciro", attached: false),
            ],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [card1, card2], snapshot: snapshot)

        // Should NOT match either — ambiguous, both have nil projectPath + tmux at same path
        // Falls through to later steps or creates new card
        #expect(result.links.count == 3) // 2 existing + 1 new discovered
    }

    @Test("Step 2 matches via tmux path when card has projectPath set")
    func step2WithProjectPathStillWorks() {
        // Card has projectPath set (the fix-1 case, after launchCard stores it)
        let taskCard = Link(
            id: "task-1",
            name: "CB",
            projectPath: "/Users/ciro",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-task-1")
        )

        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro"
        session.slug = "random-slug"
        session.messageCount = 1
        session.modifiedTime = .now

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [TmuxSession(name: "ciro-task-1", path: "/Users/ciro", attached: false)],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [taskCard], snapshot: snapshot)

        #expect(result.links.count == 1)
        #expect(result.links.first?.id == "task-1")
    }

    @Test("Step 2 disambiguates by tmux path when two cards have same projectPath")
    func step2DisambiguatesByTmuxPath() {
        // Two cards with same projectPath but different tmux sessions at different paths
        let card1 = Link(
            id: "task-a",
            name: "task A",
            projectPath: "/Users/ciro",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-task-a")
        )
        let card2 = Link(
            id: "task-b",
            name: "task B",
            projectPath: "/Users/ciro",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "ciro-task-b")
        )

        var session = Session(id: "session-1")
        session.projectPath = "/Users/ciro"
        session.slug = "some-slug"
        session.messageCount = 1
        session.modifiedTime = .now

        // Only card1's tmux has matching path
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [session],
            tmuxSessions: [
                TmuxSession(name: "ciro-task-a", path: "/Users/ciro", attached: false),
                TmuxSession(name: "ciro-task-b", path: "/different/project", attached: false),
            ],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [card1, card2], snapshot: snapshot)

        // card1's tmux path matches, card2's doesn't → solo match
        // This depends on implementation — if ambiguity check uses tmux path too
        // With both having projectPath=/Users/ciro but only card1's tmux at /Users/ciro,
        // we'd expect card1 to match
        #expect(result.links.count == 2) // card1 matched, card2 stays
        let matched = result.links.first(where: { $0.sessionLink?.sessionId == "session-1" })
        #expect(matched?.id == "task-a")
    }

    // MARK: - Priority tests

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
