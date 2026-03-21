# Hook-Authoritative Reconciler Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the hook the single authority for linking sessions to managed cards, eliminating the 6-strategy heuristic matching that causes duplicate cards.

**Architecture:** New `.hookSessionLinked` action writes session links to in-memory AppState. Reconciler simplified to: update activity on already-linked cards, create discovered cards for unmatched sessions, clean dead tmux. All heuristic matching and slug dedup deleted.

**Tech Stack:** Swift 6.2, SwiftUI, swift-testing, macOS 26

---

### Task 1: Add `.hookSessionLinked` Reducer Action

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift` (Action enum + Reducer)
- Test: `Tests/ClaudeBoardCoreTests/ReducerTests.swift`

**Step 1: Write the failing test**

Add to `ReducerTests.swift`:

```swift
// MARK: - Hook Session Linked

@Test("hookSessionLinked sets sessionLink on card and clears isLaunching")
func hookSessionLinkedSetsSession() {
    var link = makeLink(id: "card_hook1", column: .inProgress, isLaunching: true)
    var state = stateWith([link])

    let effects = reduceAndRebuild(state: &state, action: .hookSessionLinked(
        cardId: "card_hook1",
        sessionId: "sess-abc123",
        path: "/path/to/session.jsonl"
    ))

    let updated = state.links["card_hook1"]!
    #expect(updated.sessionLink?.sessionId == "sess-abc123")
    #expect(updated.sessionLink?.sessionPath == "/path/to/session.jsonl")
    #expect(updated.isLaunching == nil)
    #expect(effects.contains(where: { if case .upsertLink = $0 { return true }; return false }))
}

@Test("hookSessionLinked chains session when card already has different sessionId")
func hookSessionLinkedChainsSession() {
    var link = makeLink(
        id: "card_hook2",
        column: .inProgress,
        sessionLink: SessionLink(
            sessionId: "old-session",
            sessionPath: "/path/to/old.jsonl",
            slug: "my-slug"
        )
    )
    var state = stateWith([link])

    let _ = reduceAndRebuild(state: &state, action: .hookSessionLinked(
        cardId: "card_hook2",
        sessionId: "new-session",
        path: "/path/to/new.jsonl"
    ))

    let updated = state.links["card_hook2"]!
    #expect(updated.sessionLink?.sessionId == "new-session")
    #expect(updated.sessionLink?.sessionPath == "/path/to/new.jsonl")
    #expect(updated.sessionLink?.previousSessionPaths == ["/path/to/old.jsonl"])
}

@Test("hookSessionLinked ignores unknown cardId")
func hookSessionLinkedUnknownCard() {
    var state = AppState()

    let effects = reduceAndRebuild(state: &state, action: .hookSessionLinked(
        cardId: "nonexistent",
        sessionId: "sess-abc",
        path: nil
    ))

    #expect(effects.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter "ReducerTests/hookSessionLinked" 2>&1 | tail -20`
Expected: Compile error — `hookSessionLinked` doesn't exist on `Action`

**Step 3: Write minimal implementation**

In `BoardStore.swift`, add the action case after the existing async completions block (after line 171):

```swift
    // Hook-authoritative session linking
    case hookSessionLinked(cardId: String, sessionId: String, path: String?)
```

In the `Reducer.reduce` function, add the case handling (before the `// MARK: Background Reconciliation` section):

```swift
        // MARK: Hook-Authoritative Session Linking

        case .hookSessionLinked(let cardId, let sessionId, let path):
            guard var link = state.links[cardId] else { return [] }

            if let existingSession = link.sessionLink, existingSession.sessionId != sessionId {
                // Context continuation — chain the old session
                var pathSet = Set(existingSession.previousSessionPaths ?? [])
                if let oldPath = existingSession.sessionPath {
                    pathSet.insert(oldPath)
                }
                if let newPath = path { pathSet.remove(newPath) }
                link.sessionLink = SessionLink(
                    sessionId: sessionId,
                    sessionPath: path,
                    slug: existingSession.slug,
                    previousSessionPaths: pathSet.isEmpty ? nil : pathSet.sorted()
                )
            } else if link.sessionLink?.sessionId == sessionId {
                // Same session — just update path
                link.sessionLink?.sessionPath = path
            } else {
                // First session link
                link.sessionLink = SessionLink(sessionId: sessionId, sessionPath: path)
            }

            link.isLaunching = nil
            link.lastActivity = .now
            link.updatedAt = .now
            state.links[cardId] = link
            ClaudeBoardLog.info("store", "Hook linked session \(sessionId.prefix(8)) → card \(cardId.prefix(12))")
            return [.upsertLink(link)]
```

**Step 4: Run test to verify it passes**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter "ReducerTests/hookSessionLinked" 2>&1 | tail -20`
Expected: All 3 tests PASS

**Step 5: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift Tests/ClaudeBoardCoreTests/ReducerTests.swift
git commit -m "feat: add hookSessionLinked reducer action for hook-authoritative session linking"
git push
```

---

### Task 2: Wire Hook to Dispatch `.hookSessionLinked`

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift`

**Step 1: Replace `resolveLink` calls with dispatch**

In `processHookEvents()`, replace the `SessionStart` handling (lines 152-164) with:

```swift
                case "SessionStart":
                    if let tmuxName = event.tmuxSessionName, !tmuxName.isEmpty {
                        ClaudeBoardLog.info("notify", "SessionStart for \(event.sessionId.prefix(8)) in tmux \(tmuxName)")
                        // Extract card ID from tmux name (format: "projectName-card_XXXX...")
                        // The card ID starts with "card_" and is embedded in the tmux name
                        if let cardId = Self.extractCardId(from: tmuxName), let dispatch {
                            await dispatch(.hookSessionLinked(
                                cardId: cardId,
                                sessionId: event.sessionId,
                                path: event.transcriptPath
                            ))
                        }
                    }
```

Also replace the initial-load `SessionStart` resolution (lines 118-129) with the same approach:

```swift
                    if normalized == "SessionStart",
                       let tmuxName = event.tmuxSessionName, !tmuxName.isEmpty,
                       let cardId = Self.extractCardId(from: tmuxName), let dispatch {
                        await dispatch(.hookSessionLinked(
                            cardId: cardId,
                            sessionId: event.sessionId,
                            path: event.transcriptPath
                        ))
                        resolvedCount += 1
                    }
```

**Step 2: Add the `extractCardId` helper**

Add after `resolveLink` (which we'll delete in Task 5):

```swift
    /// Extract the card ID from a tmux session name.
    /// Format: "projectName-card_XXXX..." → "card_XXXX..."
    /// Returns nil if the tmux name doesn't contain a card ID (external session).
    static func extractCardId(from tmuxName: String) -> String? {
        // Card IDs are KSUIDs with prefix "card_" (e.g., "card_3BF58La4r0WMlluVprJcjqepLUD")
        guard let range = tmuxName.range(of: "card_") else { return nil }
        return String(tmuxName[range.lowerBound...])
    }
```

**Step 3: Run all tests**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -20`
Expected: All tests pass (old reconciler tests still pass — reconciler unchanged yet)

**Step 4: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift
git commit -m "feat: wire SessionStart hook to dispatch hookSessionLinked instead of SQLite write"
git push
```

---

### Task 3: Rewrite CardReconciler

**Files:**
- Rewrite: `Sources/ClaudeBoardCore/UseCases/CardReconciler.swift`
- Rewrite: `Tests/ClaudeBoardCoreTests/CardReconcilerTests.swift`

**Step 1: Write new tests first**

Replace the entire contents of `CardReconcilerTests.swift`:

```swift
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
            sessionLink: SessionLink(
                sessionId: "session-A",
                sessionPath: "/path/to/A.jsonl"
            )
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

        let result = CardReconciler.reconcile(existing: [existingLink], snapshot: snapshot)

        #expect(result.links.count == 1)
        let card = result.links.first!
        #expect(card.id == "card-1")
        #expect(card.lastActivity == Date(timeIntervalSince1970: 2000))
        #expect(card.sessionLink?.sessionPath == "/path/to/A-updated.jsonl")
        #expect(card.sessionLink?.slug == "some-slug")
    }

    @Test("Managed card is not hijacked by stale session from same project")
    func managedCardNotHijacked() {
        // Managed card with tmux, no session link yet (hook hasn't fired)
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

        // Managed card should NOT get the stale session — it should stay sessionLink=nil
        let managed = result.links.first(where: { $0.id == "card-managed" })!
        #expect(managed.sessionLink == nil)
        #expect(managed.tmuxLink != nil)

        // Stale session should become a separate discovered card
        #expect(result.links.count == 2)
        let discovered = result.links.first(where: { $0.id != "card-managed" })!
        #expect(discovered.sessionLink?.sessionId == "stale-session")
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
        #expect(card.sessionLink?.sessionId == "new-session")
        #expect(card.tmuxLink == nil)
        #expect(card.projectPath == "/test")
    }

    @Test("Archived card is not duplicated by its own session")
    func archivedCardNotDuplicated() {
        var archived = Link(
            id: "card-archived",
            projectPath: "/test",
            column: .done,
            source: .manual,
            sessionLink: SessionLink(sessionId: "sess-old"),
            manuallyArchived: true
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

        let result = CardReconciler.reconcile(existing: [archived], snapshot: snapshot)

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

    @Test("Manual tmux override is not cleared even when dead")
    func manualTmuxOverridePreserved() {
        var link = Link(
            id: "card-1",
            column: .waiting,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "manual-tmux")
        )
        link.manualOverrides.tmuxSession = true

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [],
            tmuxSessions: [],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)

        #expect(result.links.first!.tmuxLink?.sessionName == "manual-tmux")
    }

    // MARK: - Mixed scenarios

    @Test("Multiple sessions: linked ones update, unlinked ones create discovered cards")
    func mixedLinkedAndUnlinked() {
        let managed = Link(
            id: "card-managed",
            projectPath: "/test",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(sessionId: "sess-1")
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

        let result = CardReconciler.reconcile(existing: [managed], snapshot: snapshot)

        #expect(result.links.count == 2) // managed + 1 discovered
        let managedResult = result.links.first(where: { $0.id == "card-managed" })!
        #expect(managedResult.sessionLink?.sessionId == "sess-1")
        let discovered = result.links.first(where: { $0.id != "card-managed" })!
        #expect(discovered.source == .discovered)
        #expect(discovered.sessionLink?.sessionId == "sess-2")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter "CardReconcilerTests" 2>&1 | tail -30`
Expected: `managedCardNotHijacked` FAILS (old reconciler would match via projectPath+tmux)

**Step 3: Rewrite `CardReconciler.swift`**

Replace the entire file:

```swift
import Foundation

/// Pure reconciliation logic — simplified hook-authoritative version.
///
/// Responsibilities:
/// - Update lastActivity for cards that already have a session link
/// - Create discovered cards for truly unmatched sessions
/// - Clear dead tmux links
///
/// NOT responsible for: linking sessions to managed cards (the hook does that),
/// column assignment, activity detection.
public enum CardReconciler {

    /// A point-in-time snapshot of all discovered external resources.
    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let didScanTmux: Bool

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            didScanTmux: Bool = false
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.didScanTmux = didScanTmux
        }
    }

    /// Result of reconciliation.
    public struct ReconcileResult: Sendable {
        public let links: [Link]
    }

    /// Reconcile existing cards with discovered resources.
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> ReconcileResult {
        var linksById: [String: Link] = [:]
        for link in existing {
            linksById[link.id] = link
        }

        // Build sessionId → cardId index for O(1) lookup
        var cardIdBySessionId: [String: String] = [:]
        for link in existing {
            if let sid = link.sessionLink?.sessionId {
                cardIdBySessionId[sid] = link.id
            }
        }

        // A. Process discovered sessions
        for session in snapshot.sessions {
            if let cardId = cardIdBySessionId[session.id],
               var link = linksById[cardId] {
                // Session already linked to a card — update metadata
                if link.manuallyArchived {
                    continue // Archived cards stay archived
                }
                link.sessionLink?.sessionPath = session.jsonlPath
                if let slug = session.slug {
                    link.sessionLink?.slug = slug
                }
                link.lastActivity = session.modifiedTime
                if link.projectPath == nil, let pp = session.projectPath {
                    link.projectPath = pp
                }
                linksById[cardId] = link
            } else {
                // Truly unmatched session — create discovered card
                ClaudeBoardLog.info("reconciler", "New session \(session.id.prefix(8)) → discovered card")
                let newLink = Link(
                    projectPath: session.projectPath,
                    column: .done,
                    lastActivity: session.modifiedTime,
                    source: .discovered,
                    sessionLink: SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath,
                        slug: session.slug
                    )
                )
                linksById[newLink.id] = newLink
                cardIdBySessionId[session.id] = newLink.id
            }
        }

        // B. Clear dead tmux links
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))
        let didScanTmux = snapshot.didScanTmux

        for (id, var link) in linksById {
            guard var tmux = link.tmuxLink,
                  !link.manualOverrides.tmuxSession,
                  didScanTmux else { continue }

            var changed = false
            let primaryAlive = liveTmuxNames.contains(tmux.sessionName)

            // Filter dead extra sessions
            if let extras = tmux.extraSessions {
                let liveExtras = extras.filter { liveTmuxNames.contains($0) }
                tmux.extraSessions = liveExtras.isEmpty ? nil : liveExtras
            }

            if !primaryAlive && tmux.extraSessions == nil {
                link.tmuxLink = nil
                changed = true
            } else if !primaryAlive {
                tmux.isPrimaryDead = true
                link.tmuxLink = tmux
                changed = true
            } else {
                if tmux.isPrimaryDead != nil {
                    tmux.isPrimaryDead = nil
                }
                if tmux != link.tmuxLink {
                    link.tmuxLink = tmux
                    changed = true
                }
            }

            if changed {
                linksById[id] = link
            }
        }

        return ReconcileResult(links: Array(linksById.values))
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter "CardReconcilerTests" 2>&1 | tail -20`
Expected: All 8 tests PASS

**Step 5: Run full test suite**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -20`
Expected: All tests pass. Some other tests might reference `isLaunching` on reconciler — fix if needed.

**Step 6: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoardCore/UseCases/CardReconciler.swift Tests/ClaudeBoardCoreTests/CardReconcilerTests.swift
git commit -m "feat!: rewrite CardReconciler — hook-authoritative, no heuristic matching"
git push
```

---

### Task 4: Simplify `.reconciled` Merge Logic

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift` (`.reconciled` case, lines ~792-927)

**Step 1: Read current `.reconciled` handler**

The current handler has `isLaunching` preservation, `preservedIds`, and complex merge
logic. Simplify to: updatedAt comparison + add new discovered cards.

**Step 2: Replace the `.reconciled` handler**

Replace the body of `case .reconciled(let result):` with:

```swift
        case .reconciled(let result):
            state.tmuxSessions = result.tmuxSessions
            state.configuredProjects = result.configuredProjects
            state.excludedPaths = result.excludedPaths
            state.discoveredProjectPaths = result.discoveredProjectPaths

            // Rebuild sessions map
            state.sessions = Dictionary(
                result.sessions.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            state.activityMap = result.activityMap

            // Merge reconciled links with in-memory state.
            // In-memory wins when it has a newer updatedAt (user action during reconciliation).
            var mergedLinks = state.links
            for link in result.links {
                // Skip deliberately deleted cards/sessions
                if state.deletedCardIds.contains(link.id) { continue }
                if let sessionId = link.sessionLink?.sessionId, state.deletedSessionIds.contains(sessionId) { continue }

                if let existing = mergedLinks[link.id] {
                    // In-memory is newer — preserve it, skip reconciled data
                    if existing.updatedAt > link.updatedAt { continue }

                    // Reconciled data is newer — take it, but preserve user overrides
                    var merged = link
                    if existing.manualOverrides.name {
                        merged.name = existing.name
                        merged.manualOverrides.name = true
                    }
                    if existing.manuallyArchived {
                        merged.manuallyArchived = true
                        merged.column = .done
                    }
                    if existing.manualOverrides.column {
                        merged.column = existing.column
                        merged.manualOverrides.column = true
                    }
                    mergedLinks[link.id] = merged
                } else {
                    // New card from reconciler (discovered)
                    mergedLinks[link.id] = link
                }
            }

            // Recompute columns based on activity
            let liveTmuxNames = result.tmuxSessions
            for (id, var link) in mergedLinks where link.isLaunching != true {
                let activity = result.activityMap[link.sessionLink?.sessionId ?? ""]
                let hasLiveTmux = link.tmuxLink.map { tmux in
                    guard tmux.isShellOnly != true else { return false }
                    return tmux.allSessionNames.contains(where: { liveTmuxNames.contains($0) })
                } ?? false

                // Clear manual column override when we have definitive data
                if link.manualOverrides.column && link.column != .backlog {
                    if activity != nil && activity != .stale {
                        link.manualOverrides.column = false
                    } else if link.tmuxLink != nil && !hasLiveTmux {
                        link.tmuxLink = nil
                        link.manualOverrides.column = false
                    }
                }

                UpdateCardColumn.update(
                    link: &link,
                    activityState: activity,
                    hasLiveTmux: hasLiveTmux
                )

                // Copy session's firstPrompt into link.promptBody
                if link.promptBody == nil,
                   let sessionId = link.sessionLink?.sessionId,
                   let session = result.sessions.first(where: { $0.id == sessionId }),
                   let firstPrompt = session.firstPrompt, !firstPrompt.isEmpty {
                    link.promptBody = firstPrompt
                }

                mergedLinks[id] = link
            }

            state.links = mergedLinks
            state.lastRefresh = Date()
            state.isLoading = false

            // Validate selected card still exists
            if let selectedId = state.selectedCardId,
               !mergedLinks.keys.contains(selectedId) {
                state.selectedCardId = nil
            }

            return [.persistLinks(Array(mergedLinks.values))]
```

**Step 3: Run full test suite**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 4: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "refactor: simplify .reconciled merge — remove isLaunching preservation and preservedIds"
git push
```

---

### Task 5: Delete Dead Code

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift` — delete `resolveLink()`
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift` — remove `isLaunching` guards from `.reconciled` comment about "enables reconciler Step 2 matching" in `.launchCard`

**Step 1: Delete `resolveLink` from BackgroundOrchestrator**

Delete the entire `resolveLink` static method (lines ~348-378) and the `coordinationStore`
references only used by it. Keep `coordinationStore` itself — it's used for reading links
in `updateActivityStates()`.

**Step 2: Clean up `launchCard` comment**

In `.launchCard` handler (line ~295), change:
```swift
            // Store projectPath if not already set — enables reconciler Step 2 matching
            // for name-only TASK cards that launch without a projectPath
```
to:
```swift
            // Store projectPath if not already set
```

**Step 3: Run full test suite**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 4: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "chore: delete resolveLink and stale reconciler comments"
git push
```

---

### Task 6: Deploy and Smoke Test

**Step 1: Deploy**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && make deploy`

**Step 2: Smoke test**

1. Create a new card (double-click a column)
2. Verify it launches in tmux
3. Verify it shows as In Progress (not a duplicate)
4. Stop claude in the terminal — card should move to Waiting
5. Resume — card moves back to In Progress
6. Check logs for hook-authoritative linking:

Run: `grep "Hook linked\|hookSessionLinked\|discovered card" ~/.kanban-code/logs/kanban-code.log | tail -10`

Expected: `Hook linked session XXXX → card YYYY` log entries, no "NO MATCH" entries for managed cards.

**Step 3: Commit any fixes**

If smoke test reveals issues, fix and commit each fix separately.
