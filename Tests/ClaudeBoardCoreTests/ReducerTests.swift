import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("Reducer")
struct ReducerTests {
    // MARK: - Helpers

    private func makeLink(
        id: String = "card_test123",
        column: ClaudeBoardColumn = .backlog,
        tmuxLink: TmuxLink? = nil,
        sessionLink: SessionLink? = nil,
        isLaunching: Bool? = nil,
        source: LinkSource = .manual,
        name: String? = "Test card",
        updatedAt: Date = .now
    ) -> Link {
        Link(
            id: id,
            name: name,
            projectPath: "/test/project",
            column: column,
            updatedAt: updatedAt,
            source: source,
            sessionLink: sessionLink,
            tmuxLink: tmuxLink,
            isLaunching: isLaunching
        )
    }

    private func stateWith(_ links: [Link]) -> AppState {
        var state = AppState()
        for link in links {
            state.links[link.id] = link
        }
        return state
    }

    /// Reduce and rebuild cards to mirror BoardStore.dispatch behavior.
    private func reduceAndRebuild(state: inout AppState, action: Action) -> [Effect] {
        let effects = Reducer.reduce(state: &state, action: action)
        state.rebuildCards()
        return effects
    }

    // MARK: - Create Manual Task

    @Test("createManualTask adds link to state")
    func createManualTask() {
        var state = AppState()
        let link = makeLink(id: "card_new1", column: .backlog)

        let effects = Reducer.reduce(state: &state, action: .createManualTask(link))

        #expect(state.links["card_new1"] != nil)
        #expect(state.links["card_new1"]?.column == .backlog)
        #expect(effects.count == 1) // upsertLink
    }

    // MARK: - Create Terminal

    @Test("createTerminal sets tmuxLink but does NOT change column")
    func createTerminalKeepsColumn() {
        let link = makeLink(id: "card_t1", column: .waiting)
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_t1"))

        #expect(state.links["card_t1"]?.column == .waiting) // column unchanged!
        #expect(state.links["card_t1"]?.tmuxLink != nil)
        #expect(state.links["card_t1"]?.tmuxLink?.isShellOnly == true)
        #expect(state.links["card_t1"]?.tmuxLink?.sessionName == "project-card_t1")
        #expect(effects.contains(where: { if case .createTmuxSession = $0 { return true }; return false }))
    }

    @Test("createTerminal uses card ID for tmux name, not project name")
    func createTerminalUniqueNaming() {
        let link1 = makeLink(id: "card_abc123def4", column: .waiting)
        let link2 = makeLink(id: "card_xyz789ghi0", column: .waiting)
        var state = stateWith([link1, link2])

        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_abc123def4"))
        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_xyz789ghi0"))

        let name1 = state.links["card_abc123def4"]?.tmuxLink?.sessionName ?? ""
        let name2 = state.links["card_xyz789ghi0"]?.tmuxLink?.sessionName ?? ""
        #expect(name1 != name2)
        #expect(name1.hasPrefix("project-"))
        #expect(name2.hasPrefix("project-"))
    }

    // MARK: - Launch Card

    @Test("launchCard sets column to inProgress and isLaunching")
    func launchCardImmediateFeedback() {
        let link = makeLink(id: "card_l1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_l1", prompt: "test", projectPath: "/test",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))

        #expect(state.links["card_l1"]?.column == .inProgress)
        #expect(state.links["card_l1"]?.isLaunching == true)
        #expect(state.links["card_l1"]?.tmuxLink != nil)
        #expect(state.selectedCardId == "card_l1")
    }

    // MARK: - Resume Card

    @Test("resumeCard sets column to inProgress and isLaunching")
    func resumeCardImmediateFeedback() {
        let link = makeLink(
            id: "card_r1",
            column: .waiting,
            sessionLink: SessionLink(sessionId: "sess_abc12345")
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: "card_r1"))

        #expect(state.links["card_r1"]?.column == .inProgress)
        #expect(state.links["card_r1"]?.isLaunching == true)
        #expect(state.links["card_r1"]?.tmuxLink?.sessionName == "claude-sess_abc")
        #expect(state.selectedCardId == "card_r1")
    }

    @Test("resumeCard does not bounce — isLaunching prevents reconciliation override")
    func resumeCardNoBounce() {
        let link = makeLink(
            id: "card_r2",
            column: .waiting,
            sessionLink: SessionLink(sessionId: "sess_def12345")
        )
        var state = stateWith([link])

        // Step 1: User resumes
        let _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: "card_r2"))
        #expect(state.links["card_r2"]?.column == .inProgress)
        #expect(state.links["card_r2"]?.isLaunching == true)

        // Step 2: Background reconciliation fires with stale snapshot (taken BEFORE resume)
        let reconciledLink = makeLink(
            id: "card_r2",
            column: .waiting, // reconciliation would compute waiting (no activity yet)
            sessionLink: SessionLink(sessionId: "sess_def12345"),
            updatedAt: .now.addingTimeInterval(-5) // stale: from before the resume
        )
        let result = ReconciliationResult(
            links: [reconciledLink],
            sessions: [],
            activityMap: [:],
            tmuxSessions: []
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Card should STILL be inProgress (preserved because updatedAt is newer)
        #expect(state.links["card_r2"]?.column == .inProgress)
        #expect(state.links["card_r2"]?.isLaunching == true)
    }

    @Test("resumeCompleted clears isLaunching so terminal shows immediately")
    func resumeCompletedClearsLaunching() {
        let link = makeLink(
            id: "card_r3",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "claude-sess_abc"),
            sessionLink: SessionLink(sessionId: "sess_abc12345"),
            isLaunching: true
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .resumeCompleted(
            cardId: "card_r3", tmuxName: "claude-sess_abc"
        ))

        // isLaunching cleared immediately — terminal shows without waiting for reconciliation
        #expect(state.links["card_r3"]?.isLaunching == nil)
        #expect(state.links["card_r3"]?.column == .inProgress)
        #expect(state.links["card_r3"]?.lastActivity != nil)
    }

    // MARK: - Launch Failure

    @Test("launchFailed clears tmuxLink and isLaunching, sets error")
    func launchFailedReverts() {
        let link = makeLink(
            id: "card_f1",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "test-tmux"),
            isLaunching: true
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchFailed(
            cardId: "card_f1", error: "Connection refused"
        ))

        #expect(state.links["card_f1"]?.tmuxLink == nil)
        #expect(state.links["card_f1"]?.isLaunching == nil)
        #expect(state.error == "Launch failed: Connection refused")
    }

    // MARK: - Move Card

    @Test("moveCard sets column and manual override")
    func moveCardManualOverride() {
        let link = makeLink(id: "card_m1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .moveCard(cardId: "card_m1", to: .inProgress))

        #expect(state.links["card_m1"]?.column == .inProgress)
        #expect(state.links["card_m1"]?.manualOverrides.column == true)
    }

    @Test("moveCard to done sets manuallyArchived")
    func moveCardToArchive() {
        let link = makeLink(id: "card_m2", column: .inProgress)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .moveCard(cardId: "card_m2", to: .done))

        #expect(state.links["card_m2"]?.column == .done)
        #expect(state.links["card_m2"]?.manuallyArchived == true)
    }

    @Test("reorderCard updates sort order within a column")
    func reorderCardWithinColumn() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeLink(id: "card_1", column: .backlog, updatedAt: timestamp)
        let second = makeLink(id: "card_2", column: .backlog, updatedAt: timestamp)
        let third = makeLink(id: "card_3", column: .backlog, updatedAt: timestamp)
        var state = stateWith([first, second, third])
        state.rebuildCards()

        let effects = reduceAndRebuild(state: &state, action: .reorderCard(cardId: "card_3", targetCardId: "card_1", above: true))

        #expect(state.cards(in: .backlog).map(\.id) == ["card_3", "card_1", "card_2"])
        #expect(state.links["card_3"]?.sortOrder == 0)
        #expect(state.links["card_1"]?.sortOrder == 1)
        #expect(state.links["card_2"]?.sortOrder == 2)
        #expect(effects.count == 3)
    }

    // MARK: - Delete Card

    @Test("deleteCard removes link and returns cleanup effects")
    func deleteCardCleansUp() {
        let link = makeLink(
            id: "card_d1",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "test-tmux", extraSessions: ["test-tmux-sh1"]),
            sessionLink: SessionLink(sessionId: "sess_123", sessionPath: "/path/to/sess.jsonl")
        )
        var state = stateWith([link])
        state.selectedCardId = "card_d1"

        let effects = Reducer.reduce(state: &state, action: .deleteCard(cardId: "card_d1"))

        #expect(state.links["card_d1"] == nil)
        #expect(state.selectedCardId == nil) // deselected
        #expect(effects.contains(where: { if case .removeLink = $0 { return true }; return false }))
        #expect(effects.contains(where: { if case .killTmuxSessions = $0 { return true }; return false }))
        #expect(effects.contains(where: { if case .deleteSessionFile = $0 { return true }; return false }))
        #expect(effects.contains(where: { if case .cleanupTerminalCache = $0 { return true }; return false }))
    }

    // MARK: - Rename Card

    @Test("renameCard sets name and manual override")
    func renameCard() {
        let link = makeLink(id: "card_n1", name: "Old name")
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .renameCard(cardId: "card_n1", name: "New name"))

        #expect(state.links["card_n1"]?.name == "New name")
        #expect(state.links["card_n1"]?.manualOverrides.name == true)
    }

    // MARK: - Unlink

    @Test("unlinkFromCard clears the specified link type")
    func unlinkTypes() {
        let link = makeLink(
            id: "card_u1",
            tmuxLink: TmuxLink(sessionName: "tmux1")
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .unlinkFromCard(cardId: "card_u1", linkType: .tmux))
        #expect(state.links["card_u1"]?.tmuxLink == nil)
    }

    // MARK: - Kill Terminal

    @Test("killTerminal removes extra session and kills tmux")
    func killTerminal() {
        let link = makeLink(
            id: "card_k1",
            tmuxLink: TmuxLink(sessionName: "main", extraSessions: ["main-sh1", "main-sh2"])
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .killTerminal(
            cardId: "card_k1", sessionName: "main-sh1"
        ))

        #expect(state.links["card_k1"]?.tmuxLink?.extraSessions == ["main-sh2"])
        #expect(effects.contains(where: { if case .killTmuxSession("main-sh1") = $0 { return true }; return false }))
    }

    // MARK: - Reconciliation

    @Test("reconciled preserves cards modified during reconciliation window (updatedAt comparison)")
    func reconciledPreservesNewerCards() {
        // Simulate: reconciliation snapshot was taken at T=0, then user launched a card at T=1.
        // Reconciled data is stale (from T=0 snapshot). In-memory state is fresh (from T=1).
        let snapshotTime = Date.now.addingTimeInterval(-5) // T=0: before launch

        let launching = makeLink(
            id: "card_launching",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "claude-sess_abc"),
            isLaunching: true
            // updatedAt defaults to .now (T=1: after snapshot)
        )
        let idle = makeLink(id: "card_idle", column: .backlog, updatedAt: snapshotTime)
        var state = stateWith([launching, idle])

        // Reconciled data based on stale snapshot (older updatedAt)
        let reconciledLaunching = makeLink(
            id: "card_launching",
            column: .waiting, // stale snapshot would compute waiting
            updatedAt: snapshotTime
        )
        let reconciledIdle = makeLink(id: "card_idle", column: .done, updatedAt: snapshotTime)

        let result = ReconciliationResult(
            links: [reconciledLaunching, reconciledIdle],
            sessions: [],
            activityMap: [:],
            tmuxSessions: []
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Launching card UNCHANGED (preserved because updatedAt is newer than snapshot)
        #expect(state.links["card_launching"]?.column == .inProgress)
        #expect(state.links["card_launching"]?.isLaunching == true)
        #expect(state.links["card_launching"]?.tmuxLink?.sessionName == "claude-sess_abc")

        // Idle card updated normally (same updatedAt → reconciled data wins)
        #expect(state.links["card_idle"] != nil)
    }

    @Test("terminal created during reconciliation window survives merge")
    func terminalSurvivesReconciliation() {
        let snapshotTime = Date.now.addingTimeInterval(-3) // reconciliation started 3s ago

        // Card had no terminal at snapshot time
        let card = makeLink(id: "card_t1", column: .backlog, updatedAt: snapshotTime)
        var state = stateWith([card])

        // User creates terminal AFTER snapshot was taken → updatedAt = .now
        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_t1"))
        #expect(state.links["card_t1"]?.tmuxLink != nil)
        let tmuxName = state.links["card_t1"]!.tmuxLink!.sessionName

        // Reconciliation result arrives with stale data (no terminal)
        let staleCard = makeLink(id: "card_t1", column: .backlog, updatedAt: snapshotTime)
        let result = ReconciliationResult(
            links: [staleCard],
            sessions: [],
            activityMap: [:],
            tmuxSessions: [tmuxName] // tmux IS live
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Terminal PRESERVED (in-memory updatedAt is newer than reconciled)
        #expect(state.links["card_t1"]?.tmuxLink?.sessionName == tmuxName)
    }

    @Test("launchCompleted survives subsequent reconciliation with stale snapshot")
    func launchCompletedNotOverwritten() {
        let snapshotTime = Date.now.addingTimeInterval(-3)

        // Simulate: launchCard happened, then launchCompleted happened
        let card = makeLink(
            id: "card_lc1",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "proj-card_lc1"),
            sessionLink: SessionLink(sessionId: "sess_new123")
            // updatedAt = .now (after snapshot)
        )
        var state = stateWith([card])

        // Stale reconciliation result (from snapshot before launch)
        let staleCard = makeLink(
            id: "card_lc1",
            column: .backlog, // was backlog at snapshot time
            updatedAt: snapshotTime
        )
        let result = ReconciliationResult(
            links: [staleCard],
            sessions: [],
            activityMap: [:],
            tmuxSessions: ["proj-card_lc1"]
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Card should NOT bounce back to backlog
        #expect(state.links["card_lc1"]?.column == .inProgress)
        #expect(state.links["card_lc1"]?.tmuxLink?.sessionName == "proj-card_lc1")
        #expect(state.links["card_lc1"]?.sessionLink?.sessionId == "sess_new123")
    }

    @Test("reconciled updates sessions and activity map")
    func reconciledUpdatesMetadata() {
        var state = AppState()

        let session = Session(id: "sess_1", name: "Test", messageCount: 5, modifiedTime: .now)
        let result = ReconciliationResult(
            links: [],
            sessions: [session],
            activityMap: ["sess_1": .activelyWorking],
            tmuxSessions: ["tmux1"],
            configuredProjects: [],
            excludedPaths: ["/excluded"]
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        #expect(state.sessions["sess_1"]?.name == "Test")
        #expect(state.activityMap["sess_1"] == .activelyWorking)
        #expect(state.tmuxSessions.contains("tmux1"))
        #expect(state.excludedPaths == ["/excluded"])
    }

    // MARK: - Add Extra Terminal

    @Test("addExtraTerminal appends to extraSessions")
    func addExtraTerminal() {
        let link = makeLink(
            id: "card_e1",
            tmuxLink: TmuxLink(sessionName: "main")
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .addExtraTerminal(
            cardId: "card_e1", sessionName: "main-sh1"
        ))

        #expect(state.links["card_e1"]?.tmuxLink?.extraSessions == ["main-sh1"])
        #expect(effects.contains(where: { if case .createTmuxSession = $0 { return true }; return false }))
    }

    // MARK: - Select Card

    @Test("selectCard updates selectedCardId")
    func selectCard() {
        var state = AppState()

        let _ = Reducer.reduce(state: &state, action: .selectCard(cardId: "card_1"))
        #expect(state.selectedCardId == "card_1")

        let _ = Reducer.reduce(state: &state, action: .selectCard(cardId: nil))
        #expect(state.selectedCardId == nil)
    }

    // MARK: - Error Handling

    @Test("setError sets and clears error")
    func setError() {
        var state = AppState()

        let _ = Reducer.reduce(state: &state, action: .setError("Something went wrong"))
        #expect(state.error == "Something went wrong")

        let _ = Reducer.reduce(state: &state, action: .setError(nil))
        #expect(state.error == nil)
    }

    // MARK: - AppState Computed Properties

    @Test("cards computed property combines links, sessions, and activity")
    func cardsComputed() {
        var state = AppState()
        let link = makeLink(id: "card_c1", sessionLink: SessionLink(sessionId: "sess_1"))
        state.links["card_c1"] = link
        state.sessions["sess_1"] = Session(id: "sess_1", name: "My Session", messageCount: 3, modifiedTime: .now)
        state.activityMap["sess_1"] = .activelyWorking
        state.rebuildCards()

        let cards = state.cards
        #expect(cards.count == 1)
        #expect(cards[0].session?.name == "My Session")
        #expect(cards[0].activityState == .activelyWorking)
    }

    @Test("filteredCards respects selectedProjectPath")
    func filteredCardsProjectFilter() {
        var state = AppState()
        state.links["c1"] = makeLink(id: "c1")  // projectPath = /test/project
        let otherLink = Link(id: "c2", name: "Other", projectPath: "/other/project", column: .backlog, source: .manual)
        state.links["c2"] = otherLink
        state.rebuildCards()

        state.selectedProjectPath = "/test/project"
        #expect(state.filteredCards.count == 1)
        #expect(state.filteredCards[0].id == "c1")

        state.selectedProjectPath = nil // global view
        #expect(state.filteredCards.count == 2)
    }

    // MARK: - isShellOnly preserved through terminal creation

    @Test("createTerminal creates shell-only terminal with correct tab label")
    func createTerminalIsShellOnly() {
        let link = makeLink(id: "card_sh1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_sh1"))

        #expect(state.links["card_sh1"]?.tmuxLink?.isShellOnly == true)
        #expect(state.links["card_sh1"]?.column == .backlog) // unchanged
    }

    @Test("launchCard uses unique tmux name per card, not just project name")
    func launchCardUniqueTmuxName() {
        let link1 = makeLink(id: "card_a1", column: .backlog)
        let link2 = makeLink(id: "card_b2", column: .backlog)
        var state = stateWith([link1, link2])

        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_a1", prompt: "test", projectPath: "/test/project",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))
        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_b2", prompt: "test", projectPath: "/test/project",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))

        let name1 = state.links["card_a1"]?.tmuxLink?.sessionName ?? ""
        let name2 = state.links["card_b2"]?.tmuxLink?.sessionName ?? ""
        #expect(name1 != name2) // Different cards in same project get different tmux names
        #expect(name1.contains("project")) // Still includes project name for readability
        #expect(name1.contains("card_a1")) // Includes card ID for uniqueness
    }

    @Test("launchCard creates Claude terminal (not shell-only)")
    func launchCardNotShellOnly() {
        let link = makeLink(id: "card_cl1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_cl1", prompt: "test", projectPath: "/test",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))

        #expect(state.links["card_cl1"]?.tmuxLink?.isShellOnly != true)
    }

    // Worktree dedup tests removed (worktree feature stripped)

    // MARK: - Merge Cards

    @Test("mergeCards transfers session from source to target")
    func mergeTransfersSession() {
        let source = makeLink(
            id: "card_src",
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "sess-1", sessionPath: "/path/to/sess")
        )
        let target = makeLink(
            id: "card_tgt",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "tmux-1")
        )
        var state = stateWith([source, target])

        let effects = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        // Source removed, target gained session
        #expect(state.links["card_src"] == nil)
        #expect(state.links["card_tgt"]?.sessionLink?.sessionId == "sess-1")
        #expect(state.links["card_tgt"]?.tmuxLink?.sessionName == "tmux-1")
        #expect(state.deletedCardIds.contains("card_src"))
        // Should produce upsert + remove effects
        #expect(effects.count == 2)
    }

    @Test("mergeCards transfers tmux from source to target")
    func mergeTransfersTmux() {
        let source = makeLink(
            id: "card_src",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "tmux-1")
        )
        let target = makeLink(
            id: "card_tgt",
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "sess-1")
        )
        var state = stateWith([source, target])

        let _ = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        #expect(state.links["card_src"] == nil)
        #expect(state.links["card_tgt"]?.tmuxLink?.sessionName == "tmux-1")
        #expect(state.links["card_tgt"]?.sessionLink?.sessionId == "sess-1")
    }

    @Test("mergeCards blocked when both have sessions")
    func mergeBlockedBothSessions() {
        let source = makeLink(
            id: "card_src",
            sessionLink: SessionLink(sessionId: "sess-1")
        )
        let target = makeLink(
            id: "card_tgt",
            sessionLink: SessionLink(sessionId: "sess-2")
        )
        var state = stateWith([source, target])

        let effects = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        // Both cards should remain, error set
        #expect(state.links.count == 2)
        #expect(state.error != nil)
        #expect(effects.isEmpty)
    }

    @Test("mergeCards blocked when both have terminals")
    func mergeBlockedBothTerminals() {
        let source = makeLink(id: "card_src", tmuxLink: TmuxLink(sessionName: "t1"))
        let target = makeLink(id: "card_tgt", tmuxLink: TmuxLink(sessionName: "t2"))
        var state = stateWith([source, target])

        let effects = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        #expect(state.links.count == 2)
        #expect(state.error != nil)
        #expect(effects.isEmpty)
    }

    // mergeCards issue/PR tests removed (GitHub integration stripped)

    @Test("mergeCards preserves target fields over source")
    func mergePreservesTargetFields() {
        let source = Link(
            id: "card_src",
            name: "Source name",
            projectPath: "/source/path",
            column: .waiting,
            source: .discovered,
            promptBody: "source prompt"
        )
        let target = Link(
            id: "card_tgt",
            name: "Target name",
            projectPath: "/target/path",
            column: .inProgress,
            source: .manual,
            promptBody: "target prompt",
            sessionLink: SessionLink(sessionId: "sess-1")
        )
        var state = stateWith([source, target])

        let _ = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        let merged = state.links["card_tgt"]!
        // Target's existing fields preserved
        #expect(merged.name == "Target name")
        #expect(merged.projectPath == "/target/path")
        #expect(merged.promptBody == "target prompt")
        #expect(merged.sessionLink?.sessionId == "sess-1")
    }

    @Test("mergeCards fills nil target fields from source")
    func mergeFillsNilFields() {
        let source = Link(
            id: "card_src",
            name: "Source name",
            projectPath: "/source/path",
            column: .waiting,
            source: .discovered,
            promptBody: "source prompt"
        )
        let target = Link(
            id: "card_tgt",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "tmux-1")
        )
        var state = stateWith([source, target])

        let _ = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        let merged = state.links["card_tgt"]!
        #expect(merged.name == "Source name")
        #expect(merged.projectPath == "/source/path")
        #expect(merged.promptBody == "source prompt")
        #expect(merged.tmuxLink?.sessionName == "tmux-1")
    }

    @Test("mergeCards preserves more recent lastActivity")
    func mergePreservesRecentActivity() {
        let older = Date.now.addingTimeInterval(-3600)
        let newer = Date.now.addingTimeInterval(-60)
        var source = makeLink(id: "card_src")
        source.lastActivity = newer
        var target = makeLink(id: "card_tgt")
        target.lastActivity = older
        var state = stateWith([source, target])

        let _ = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        #expect(state.links["card_tgt"]!.lastActivity == newer)
    }

    @Test("mergeCards moves selection from source to target")
    func mergeMovesSelection() {
        let source = makeLink(id: "card_src")
        let target = makeLink(id: "card_tgt")
        var state = stateWith([source, target])
        state.selectedCardId = "card_src"

        let _ = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_src", targetId: "card_tgt"))

        #expect(state.selectedCardId == "card_tgt")
    }

    @Test("mergeCards with same card ID is a no-op")
    func mergeSameCardNoOp() {
        let card = makeLink(id: "card_1")
        var state = stateWith([card])

        let effects = Reducer.reduce(state: &state, action: .mergeCards(sourceId: "card_1", targetId: "card_1"))

        #expect(state.links.count == 1)
        #expect(effects.isEmpty)
    }

    // mergeCards isRemote test removed (remote feature stripped)

    // MARK: - Update Notes

    @Test("updateNotes sets notes on card")
    func updateNotes() {
        var state = AppState()
        let link = Link(id: "card_notes", name: "Task")
        state.links[link.id] = link
        let effects = Reducer.reduce(state: &state, action: .updateNotes(cardId: "card_notes", notes: "My notes"))
        #expect(state.links["card_notes"]!.notes == "My notes")
        #expect(!effects.isEmpty)
    }

    @Test("updateNotes clears notes with nil")
    func clearNotes() {
        var state = AppState()
        var link = Link(id: "card_clear_notes", name: "Task")
        link.notes = "Old notes"
        state.links[link.id] = link
        let _ = Reducer.reduce(state: &state, action: .updateNotes(cardId: "card_clear_notes", notes: nil))
        #expect(state.links["card_clear_notes"]!.notes == nil)
    }

    // MARK: - Link.mergeBlocked validation

    @Test("mergeBlocked returns nil for compatible cards")
    func mergeBlockedCompatible() {
        let source = Link(id: "a", column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        let target = Link(id: "b", column: .inProgress, tmuxLink: TmuxLink(sessionName: "t1"))
        #expect(Link.mergeBlocked(source: source, target: target) == nil)
    }

    @Test("mergeBlocked detects both sessions")
    func mergeBlockedBothSessionsValidation() {
        let source = Link(id: "a", column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        let target = Link(id: "b", column: .inProgress, sessionLink: SessionLink(sessionId: "s2"))
        #expect(Link.mergeBlocked(source: source, target: target) != nil)
    }

    @Test("mergeBlocked detects both terminals")
    func mergeBlockedBothTerminalsValidation() {
        let source = Link(id: "a", column: .inProgress, tmuxLink: TmuxLink(sessionName: "t1"))
        let target = Link(id: "b", column: .inProgress, tmuxLink: TmuxLink(sessionName: "t2"))
        #expect(Link.mergeBlocked(source: source, target: target) != nil)
    }

    // Worktree merge blocked tests removed (worktree feature stripped)

    @Test("mergeBlocked detects self-merge")
    func mergeBlockedSelf() {
        let card = Link(id: "a", column: .inProgress)
        #expect(Link.mergeBlocked(source: card, target: card) != nil)
    }

    // MARK: - Terminal Independence

    @Test("killTerminal primary with extras sets isPrimaryDead, preserves extras")
    func killPrimaryWithExtras() {
        let link = makeLink(
            id: "card_ti1",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "main", extraSessions: ["main-sh1", "main-sh2"])
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .killTerminal(
            cardId: "card_ti1", sessionName: "main"
        ))

        // tmuxLink preserved with isPrimaryDead
        #expect(state.links["card_ti1"]?.tmuxLink != nil)
        #expect(state.links["card_ti1"]?.tmuxLink?.isPrimaryDead == true)
        #expect(state.links["card_ti1"]?.tmuxLink?.extraSessions == ["main-sh1", "main-sh2"])
        // Only primary killed
        #expect(effects.contains(where: { if case .killTmuxSession("main") = $0 { return true }; return false }))
    }

    @Test("killTerminal primary without extras clears tmuxLink entirely")
    func killPrimaryWithoutExtras() {
        let link = makeLink(
            id: "card_ti2",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "main")
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .killTerminal(
            cardId: "card_ti2", sessionName: "main"
        ))

        #expect(state.links["card_ti2"]?.tmuxLink == nil)
    }

    @Test("killTerminal extra while primary is dead and no other extras clears tmuxLink")
    func killLastExtraWhilePrimaryDead() {
        let link = makeLink(
            id: "card_ti3",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "main", extraSessions: ["main-sh1"], isPrimaryDead: true)
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .killTerminal(
            cardId: "card_ti3", sessionName: "main-sh1"
        ))

        // Both primary and extras gone → full teardown
        #expect(state.links["card_ti3"]?.tmuxLink == nil)
    }

    @Test("killTerminal extra while primary is alive preserves everything")
    func killExtraWhilePrimaryAlive() {
        let link = makeLink(
            id: "card_ti4",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "main", extraSessions: ["main-sh1", "main-sh2"])
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .killTerminal(
            cardId: "card_ti4", sessionName: "main-sh1"
        ))

        #expect(state.links["card_ti4"]?.tmuxLink?.sessionName == "main")
        #expect(state.links["card_ti4"]?.tmuxLink?.extraSessions == ["main-sh2"])
        #expect(state.links["card_ti4"]?.tmuxLink?.isPrimaryDead != true)
    }

    @Test("cancelLaunch clears isLaunching and tmuxLink")
    func cancelLaunch() {
        let link = makeLink(
            id: "card_ti5",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "proj-card_ti5"),
            isLaunching: true
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .cancelLaunch(cardId: "card_ti5"))

        #expect(state.links["card_ti5"]?.isLaunching == nil)
        #expect(state.links["card_ti5"]?.tmuxLink == nil)
        #expect(effects.contains(where: { if case .killTmuxSession("proj-card_ti5") = $0 { return true }; return false }))
    }

    @Test("resumeCard with dead primary preserves extras")
    func resumeWithDeadPrimaryPreservesExtras() {
        let link = makeLink(
            id: "card_ti6",
            column: .waiting,
            tmuxLink: TmuxLink(sessionName: "old-main", extraSessions: ["old-main-sh1"], isPrimaryDead: true),
            sessionLink: SessionLink(sessionId: "sess_abc12345")
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: "card_ti6"))

        // Extras carried forward into new tmuxLink
        #expect(state.links["card_ti6"]?.tmuxLink?.extraSessions == ["old-main-sh1"])
        // isPrimaryDead cleared (new session launching)
        #expect(state.links["card_ti6"]?.tmuxLink?.isPrimaryDead != true)
        #expect(state.links["card_ti6"]?.isLaunching == true)
    }

    @Test("resumeCompleted preserves extras from before resume")
    func resumeCompletedPreservesExtras() {
        let link = makeLink(
            id: "card_ti7",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "claude-sess_abc", extraSessions: ["claude-sess_abc-sh1"]),
            sessionLink: SessionLink(sessionId: "sess_abc12345"),
            isLaunching: true
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .resumeCompleted(
            cardId: "card_ti7", tmuxName: "claude-sess_abc"
        ))

        #expect(state.links["card_ti7"]?.tmuxLink?.extraSessions == ["claude-sess_abc-sh1"])
        #expect(state.links["card_ti7"]?.isLaunching == nil)
    }

    @Test("launchCompleted preserves extras")
    func launchCompletedPreservesExtras() {
        let link = makeLink(
            id: "card_ti8",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "proj-card_ti8", extraSessions: ["proj-card_ti8-sh1"]),
            isLaunching: true
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchCompleted(
            cardId: "card_ti8",
            tmuxName: "proj-card_ti8",
            sessionLink: SessionLink(sessionId: "sess_new123", sessionPath: "/path/to/sess.jsonl")
        ))

        #expect(state.links["card_ti8"]?.tmuxLink?.extraSessions == ["proj-card_ti8-sh1"])
        #expect(state.links["card_ti8"]?.isLaunching == nil)
        #expect(state.links["card_ti8"]?.sessionLink?.sessionId == "sess_new123")
    }

    @Test("resumeCard on shell-only card moves shell to extras")
    func resumeOnShellOnlyMovesShellToExtras() {
        let link = makeLink(
            id: "card_ti9",
            column: .waiting,
            tmuxLink: TmuxLink(sessionName: "project-card_ti9", isShellOnly: true),
            sessionLink: SessionLink(sessionId: "sess_xyz12345")
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: "card_ti9"))

        // Shell primary moved to extras
        #expect(state.links["card_ti9"]?.tmuxLink?.extraSessions?.contains("project-card_ti9") == true)
        // New Claude session is now primary
        #expect(state.links["card_ti9"]?.tmuxLink?.isShellOnly != true)
        #expect(state.links["card_ti9"]?.tmuxLink?.sessionName.hasPrefix("claude-") == true)
    }

    // MARK: - Todoist Integration

    @Test("todoistSyncCompleted creates new cards")
    func todoistSyncCreatesNewCards() {
        var state = AppState()
        let task = TodoistTask(id: "todoist_123", content: "Buy groceries", description: "Milk, eggs")

        let effects = Reducer.reduce(state: &state, action: .todoistSyncCompleted([task]))

        let todoistLinks = state.links.values.filter { $0.todoistId == "todoist_123" }
        #expect(todoistLinks.count == 1)
        let link = todoistLinks.first!
        #expect(link.name == "Buy groceries")
        #expect(link.todoistDescription == "Milk, eggs")
        #expect(link.source == .todoist)
        #expect(link.column == .backlog)
        #expect(effects.contains(where: { if case .persistLinks = $0 { return true }; return false }))
    }

    @Test("todoistSyncCompleted matches existing by todoistId")
    func todoistSyncMatchesExistingByTodoistId() {
        let existing = Link(
            id: "card_existing",
            name: "Old name",
            column: .backlog,
            source: .todoist,
            todoistId: "todoist_456",
            todoistDescription: "Old desc"
        )
        var state = stateWith([existing])

        let task = TodoistTask(id: "todoist_456", content: "Updated name", description: "New desc")
        let _ = Reducer.reduce(state: &state, action: .todoistSyncCompleted([task]))

        #expect(state.links["card_existing"]?.name == "Updated name")
        #expect(state.links["card_existing"]?.todoistDescription == "New desc")
        // Should not create a duplicate
        let todoistLinks = state.links.values.filter { $0.todoistId == "todoist_456" }
        #expect(todoistLinks.count == 1)
    }

    @Test("todoistSyncCompleted archives missing tasks in backlog")
    func todoistSyncArchivesMissingTasks() {
        let existing = Link(
            id: "card_gone",
            name: "Completed task",
            column: .backlog,
            source: .todoist,
            todoistId: "todoist_789"
        )
        var state = stateWith([existing])

        // Sync with empty task list — the task was completed in Todoist
        let _ = Reducer.reduce(state: &state, action: .todoistSyncCompleted([]))

        #expect(state.links["card_gone"]?.column == .done)
        #expect(state.links["card_gone"]?.manuallyArchived == true)
    }

    @Test("todoistSyncCompleted does not archive non-backlog tasks")
    func todoistSyncDoesNotArchiveNonBacklog() {
        let existing = Link(
            id: "card_active",
            name: "In progress task",
            column: .inProgress,
            source: .todoist,
            todoistId: "todoist_active"
        )
        var state = stateWith([existing])

        // Sync with empty task list — but card is in progress, so don't archive
        let _ = Reducer.reduce(state: &state, action: .todoistSyncCompleted([]))

        #expect(state.links["card_active"]?.column == .inProgress)
        #expect(state.links["card_active"]?.manuallyArchived == false)
    }

    @Test("archiving a todoist card emits completeTodoistTask effect")
    func completeTodoistTaskOnArchive() {
        let link = Link(
            id: "card_todoist_archive",
            name: "Todoist task",
            column: .backlog,
            source: .todoist,
            todoistId: "todoist_complete"
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .archiveCard(cardId: "card_todoist_archive"))

        #expect(state.links["card_todoist_archive"]?.column == .done)
        #expect(effects.contains(where: {
            if case .completeTodoistTask(todoistId: "todoist_complete") = $0 { return true }
            return false
        }))
    }

    @Test("todoistSyncCompleted stores extra fields on new card")
    func todoistSyncStoresExtraFields() {
        var state = AppState()
        let task = TodoistTask(
            id: "todoist_extra",
            content: "Read article",
            description: "Some desc",
            priority: 3,
            due: "2026-03-20",
            labels: ["claude", "urgent"],
            projectId: "proj_abc"
        )

        let _ = Reducer.reduce(state: &state, action: .todoistSyncCompleted([task]))

        let link = state.links.values.first { $0.todoistId == "todoist_extra" }!
        #expect(link.todoistPriority == 3)
        #expect(link.todoistDue == "2026-03-20")
        #expect(link.todoistLabels == ["claude", "urgent"])
        #expect(link.todoistProjectId == "proj_abc")
    }

    @Test("todoistSyncCompleted updates extra fields on existing card")
    func todoistSyncUpdatesExtraFields() {
        let existing = Link(
            id: "card_update_extra",
            name: "Old",
            column: .backlog,
            source: .todoist,
            todoistId: "todoist_upd"
        )
        var state = stateWith([existing])

        let task = TodoistTask(
            id: "todoist_upd",
            content: "Updated",
            description: nil,
            priority: 4,
            due: "2026-04-01",
            labels: ["claude"],
            projectId: "proj_xyz"
        )
        let _ = Reducer.reduce(state: &state, action: .todoistSyncCompleted([task]))

        let link = state.links["card_update_extra"]!
        #expect(link.todoistPriority == 4)
        #expect(link.todoistDue == "2026-04-01")
        #expect(link.todoistLabels == ["claude"])
        #expect(link.todoistProjectId == "proj_xyz")
    }

    // MARK: - Consolidated Archive Behavior

    @Test("moveCard to done kills tmux sessions")
    func moveCardToDoneKillsTmux() {
        let tmux = TmuxLink(sessionName: "ciro-test_sess")
        var link = Link(id: "card_tmux_done", name: "Has tmux", column: .inProgress, source: .manual)
        link.tmuxLink = tmux
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .moveCard(cardId: "card_tmux_done", to: .done))

        #expect(state.links["card_tmux_done"]?.column == .done)
        #expect(state.links["card_tmux_done"]?.tmuxLink == nil)
        #expect(state.links["card_tmux_done"]?.manuallyArchived == true)
        #expect(effects.contains(where: {
            if case .killTmuxSessions = $0 { return true }
            return false
        }))
        #expect(effects.contains(where: {
            if case .cleanupTerminalCache = $0 { return true }
            return false
        }))
    }

    @Test("moveCard to done completes todoist task")
    func moveCardToDoneCompletesTodoist() {
        let link = Link(
            id: "card_move_todoist",
            name: "Todoist task",
            column: .inProgress,
            source: .todoist,
            todoistId: "todoist_move"
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .moveCard(cardId: "card_move_todoist", to: .done))

        #expect(effects.contains(where: {
            if case .completeTodoistTask(todoistId: "todoist_move") = $0 { return true }
            return false
        }))
    }

    @Test("archiveCard and moveCard to done produce same side effects")
    func archiveAndMoveProduceSameEffects() {
        // Setup two identical cards with tmux + todoist
        let tmux = TmuxLink(sessionName: "ciro-same_test")
        var link1 = Link(id: "card_archive", name: "Task", column: .inProgress, source: .todoist, todoistId: "tid_same")
        link1.tmuxLink = tmux
        var link2 = Link(id: "card_move", name: "Task", column: .inProgress, source: .todoist, todoistId: "tid_same2")
        link2.tmuxLink = TmuxLink(sessionName: "ciro-same_test2")

        var state1 = stateWith([link1])
        var state2 = stateWith([link2])

        let archiveEffects = Reducer.reduce(state: &state1, action: .archiveCard(cardId: "card_archive"))
        let moveEffects = Reducer.reduce(state: &state2, action: .moveCard(cardId: "card_move", to: .done))

        // Both should produce the same types of effects
        func effectTypes(_ effects: [Effect]) -> Set<String> {
            Set(effects.map { "\(type(of: $0)):\(String(describing: $0).components(separatedBy: "(").first ?? "")" })
        }

        // Both should: upsertLink, killTmuxSessions, cleanupTerminalCache, completeTodoistTask
        #expect(state1.links["card_archive"]?.column == .done)
        #expect(state2.links["card_move"]?.column == .done)
        #expect(state1.links["card_archive"]?.tmuxLink == nil)
        #expect(state2.links["card_move"]?.tmuxLink == nil)
        #expect(state1.links["card_archive"]?.manuallyArchived == true)
        #expect(state2.links["card_move"]?.manuallyArchived == true)

        // Same effect count (upsert + kill + cleanup + todoist complete)
        #expect(archiveEffects.count == moveEffects.count)
    }

    @Test("moveCard to non-done column does not kill tmux or complete todoist")
    func moveCardToNonDoneNoSideEffects() {
        let tmux = TmuxLink(sessionName: "ciro-keep_tmux")
        var link = Link(id: "card_keep", name: "Keep", column: .inProgress, source: .todoist, todoistId: "tid_keep")
        link.tmuxLink = tmux
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .moveCard(cardId: "card_keep", to: .waiting))

        #expect(state.links["card_keep"]?.tmuxLink != nil)
        #expect(!effects.contains(where: {
            if case .killTmuxSessions = $0 { return true }
            return false
        }))
        #expect(!effects.contains(where: {
            if case .completeTodoistTask = $0 { return true }
            return false
        }))
    }

    @Test("assignColumn keeps todoist card with no session in backlog")
    func assignColumnPreservesTodoist() {
        let link = Link(
            id: "card_todoist_backlog",
            column: .backlog,
            source: .todoist,
            todoistId: "todoist_stay"
        )
        let column = AssignColumn.assign(link: link)
        #expect(column == .backlog)
    }

    // MARK: - Project Labels

    @Test("setProject assigns projectId to card")
    func setProjectOnCard() {
        var state = AppState()
        let link = Link(id: "card_proj", name: "Task")
        state.links[link.id] = link
        let effects = Reducer.reduce(state: &state, action: .setProject(cardId: "card_proj", projectId: "proj_123"))
        #expect(state.links["card_proj"]!.projectId == "proj_123")
        #expect(!effects.isEmpty)
    }

    @Test("setProject clears projectId with nil")
    func clearProjectOnCard() {
        var state = AppState()
        var link = Link(id: "card_clear", name: "Task")
        link.projectId = "proj_old"
        state.links[link.id] = link
        let _ = Reducer.reduce(state: &state, action: .setProject(cardId: "card_clear", projectId: nil))
        #expect(state.links["card_clear"]!.projectId == nil)
    }

    @Test("launchCard on shell-only card moves shell to extras")
    func launchOnShellOnlyMovesShellToExtras() {
        let link = makeLink(
            id: "card_ti10",
            column: .backlog,
            tmuxLink: TmuxLink(sessionName: "project-card_ti10", isShellOnly: true)
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_ti10", prompt: "test", projectPath: "/test/project",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))

        // Shell primary moved to extras
        #expect(state.links["card_ti10"]?.tmuxLink?.extraSessions?.contains("project-card_ti10") == true)
        // New Claude session is now primary
        #expect(state.links["card_ti10"]?.tmuxLink?.isShellOnly != true)
    }

    // MARK: - Tab Memory

    @Test("setLastTab persists tab on link")
    func setLastTabPersists() {
        let link = makeLink(id: "card_tab1")
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .setLastTab(cardId: "card_tab1", tab: "reply"))

        #expect(state.links["card_tab1"]?.lastTab == "reply")
        #expect(effects.count == 1) // upsertLink
    }

    @Test("setLastTab updates existing tab value")
    func setLastTabUpdates() {
        var link = makeLink(id: "card_tab2")
        link.lastTab = "terminal"
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .setLastTab(cardId: "card_tab2", tab: "history"))

        #expect(state.links["card_tab2"]?.lastTab == "history")
    }

    @Test("setLastTab ignores unknown card")
    func setLastTabUnknownCard() {
        var state = AppState()

        let effects = Reducer.reduce(state: &state, action: .setLastTab(cardId: "card_unknown", tab: "reply"))

        #expect(effects.isEmpty)
    }
}
