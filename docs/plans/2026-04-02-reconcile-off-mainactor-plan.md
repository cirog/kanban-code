# Move Reconciliation Off MainActor — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop `BoardStore.reconcile()` from blocking the MainActor during heavy I/O, eliminating 3-10 second UI freezes.

**Architecture:** Split `reconcile()` into a `nonisolated` background data-gathering phase and a MainActor dispatch phase. When the `@MainActor` method hits `await` on the `nonisolated` function, it suspends — freeing the main thread for UI events. All dependencies are already actors or Sendable, so no new concurrency primitives are needed.

**Tech Stack:** Swift 6.2 structured concurrency, `@MainActor`, `nonisolated`

---

### Task 1: Define the ReconcileInputs snapshot struct

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`

**Step 1: Add the input struct after ReconciliationResult**

Add this struct inside BoardStore.swift, after line ~258 (after `ReconciliationResult`'s closing brace):

```swift
/// Value-type snapshot of state needed by background reconciliation.
/// Captured on MainActor before crossing isolation boundary.
private struct ReconcileInputs: Sendable {
    let configuredProjects: [Project]
    let excludedPaths: [String]
    let existingLinks: [Link]
    let deletedSessionIds: Set<String>
    let deletedCardIds: Set<String>
    let linksEmpty: Bool
    let sessionIdByCardId: [String: String]
}
```

**Step 2: Build and run**

Run: `cd ~/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: Build succeeded (struct is unused but valid)

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "refactor: add ReconcileInputs snapshot struct for background reconciliation"
```

---

### Task 2: Extract gatherReconciliationData as nonisolated

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`

**Step 1: Write the nonisolated gather function**

Add this method to BoardStore, after the `reconcile()` method (after line ~1412):

```swift
/// Runs all heavy I/O off MainActor. Called from reconcile() which suspends
/// the MainActor at the await point, keeping the UI responsive.
nonisolated private func gatherReconciliationData(
    inputs: ReconcileInputs
) async throws -> (
    result: ReconciliationResult,
    sessionByCard: [String: String],
    cachedLinks: [Link]?
) {
    let reconcileStart = ContinuousClock.now

    // Load cached links from DB if state was empty
    var cachedLinks: [Link]? = nil
    if inputs.linksEmpty {
        let t = ContinuousClock.now
        let cached = try await coordinationStore.readLinks()
        if !cached.isEmpty {
            cachedLinks = AutoCleanup.clean(links: cached)
        }
        ClaudeBoardLog.info("reconcile", "cached links: \(t.duration(to: .now)) (\(cached.count) links)")
    }

    // Discover sessions
    let t1 = ContinuousClock.now
    let allSessions = try await discovery.discoverSessions()
    let sessions = allSessions.filter { !inputs.deletedSessionIds.contains($0.id) }
    ClaudeBoardLog.info("reconcile", "discoverSessions: \(t1.duration(to: .now)) (\(sessions.count) sessions)")

    // Use snapshot of existing links — NOT live state
    let existingLinks = inputs.linksEmpty
        ? (cachedLinks ?? [])
        : inputs.existingLinks

    // Scan tmux sessions
    let t2 = ContinuousClock.now
    let tmuxSessions = (try? await tmuxAdapter?.listSessions()) ?? []
    ClaudeBoardLog.info("reconcile", "tmux: \(t2.duration(to: .now)) (\(tmuxSessions.count) sessions)")

    // Reconcile
    let t3 = ContinuousClock.now
    let existingAssociations = try await coordinationStore.allSessionAssociations()
    let allHookEvents: [HookEvent]
    if let hookEventStore {
        allHookEvents = try await hookEventStore.readAllStoredEvents()
    } else {
        allHookEvents = []
    }
    let snapshot = CardReconciler.DiscoverySnapshot(
        sessions: sessions,
        tmuxSessions: tmuxSessions,
        didScanTmux: tmuxAdapter != nil,
        hookEvents: allHookEvents,
        existingAssociations: existingAssociations
    )
    let reconcileResult = CardReconciler.reconcile(
        existing: existingLinks,
        snapshot: snapshot
    )
    let mergedLinks = reconcileResult.links
    let associations = reconcileResult.associations
    ClaudeBoardLog.info("reconcile", "reconciler: \(t3.duration(to: .now)) (\(existingLinks.count) existing → \(mergedLinks.count) reconciled, \(associations.count) associations)")

    // Build sessionIdByCardId
    let sessionMtimes: [String: Date] = Dictionary(
        sessions.map { ($0.id, $0.modifiedTime) },
        uniquingKeysWith: { a, b in max(a, b) }
    )
    var sessionByCard: [String: String] = [:]
    for assoc in associations {
        let existingId = sessionByCard[assoc.cardId]
        if let existingId {
            let existingMtime = sessionMtimes[existingId] ?? .distantPast
            let newMtime = sessionMtimes[assoc.sessionId] ?? .distantPast
            if newMtime > existingMtime {
                sessionByCard[assoc.cardId] = assoc.sessionId
            }
        } else {
            sessionByCard[assoc.cardId] = assoc.sessionId
        }
    }

    // PID-based process detection
    let t4 = ContinuousClock.now
    var latestPidBySession: [String: Int] = [:]
    var latestEventBySession: [String: String] = [:]
    for event in allHookEvents {
        if let pid = event.pid {
            latestPidBySession[event.sessionId] = pid
        }
        latestEventBySession[event.sessionId] = event.eventName
    }
    var pidAliveCache: [Int: Bool] = [:]
    for pid in Set(latestPidBySession.values) {
        pidAliveCache[pid] = ProcessChecker.isAlive(pid: pid)
    }
    var isClaudeRunningMap: [String: Bool] = [:]
    for (sessionId, pid) in latestPidBySession {
        isClaudeRunningMap[sessionId] = pidAliveCache[pid] ?? false
    }
    let aliveCount = isClaudeRunningMap.values.filter { $0 }.count
    ClaudeBoardLog.info("reconcile", "PID check: \(t4.duration(to: .now)) (\(latestPidBySession.count) sessions, \(aliveCount) alive)")

    // Build activity map using the snapshot's sessionIdByCardId + newly computed sessionByCard
    // Merge: start with the snapshot (previous state), overlay with new associations
    var effectiveSessionByCard = inputs.sessionIdByCardId
    for (cardId, sessionId) in sessionByCard {
        effectiveSessionByCard[cardId] = sessionId
    }
    var activityMap: [String: ActivityState] = [:]
    if let activityDetector {
        let allCardIds = Set(mergedLinks.map(\.id))
        for (cardId, sessionId) in effectiveSessionByCard {
            guard allCardIds.contains(cardId) else { continue }
            activityMap[sessionId] = await activityDetector.activityState(for: sessionId)
        }
    }

    // Compute discovered project paths
    let sessionPaths = mergedLinks.map { $0.projectPath }
    let discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
        sessionPaths: sessionPaths,
        configuredProjects: inputs.configuredProjects
    )

    let result = ReconciliationResult(
        links: mergedLinks,
        sessions: sessions,
        isClaudeRunning: isClaudeRunningMap,
        lastHookEvent: latestEventBySession,
        activityMap: activityMap,
        tmuxSessions: Set(tmuxSessions.map(\.name)),
        configuredProjects: inputs.configuredProjects,
        excludedPaths: inputs.excludedPaths,
        discoveredProjectPaths: discoveredProjectPaths,
        associations: associations
    )

    ClaudeBoardLog.info("reconcile", "TOTAL (background): \(reconcileStart.duration(to: .now))")
    return (result, sessionByCard, cachedLinks)
}
```

**Step 2: Build**

Run: `cd ~/Playground/Development/claudeboard && swift build 2>&1 | tail -10`
Expected: Build succeeded (new method exists but isn't called yet)

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "refactor: extract gatherReconciliationData as nonisolated method"
```

---

### Task 3: Rewrite reconcile() to delegate to background

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`

**Step 1: Replace reconcile() body**

Replace the entire `reconcile()` method (lines 1243-1412) with:

```swift
public func reconcile() async {
    guard !isReconciling else { return }
    isReconciling = true
    defer { isReconciling = false }

    dispatch(.setLoading(true))

    do {
        // Settings fallback — read from disk if not yet loaded
        var configuredProjects = state.configuredProjects
        var excludedPaths = state.excludedPaths
        if configuredProjects.isEmpty, let store = settingsStore {
            if let settings = try? await store.read() {
                configuredProjects = settings.projects
                excludedPaths = settings.globalView.excludedPaths
                dispatch(.settingsLoaded(projects: configuredProjects, excludedPaths: excludedPaths, projectLabels: settings.projectLabels))
            }
        }

        // Snapshot state on MainActor (cheap copies)
        let inputs = ReconcileInputs(
            configuredProjects: configuredProjects,
            excludedPaths: excludedPaths,
            existingLinks: Array(state.links.values),
            deletedSessionIds: state.deletedSessionIds,
            deletedCardIds: state.deletedCardIds,
            linksEmpty: state.links.isEmpty,
            sessionIdByCardId: state.sessionIdByCardId
        )

        // --- MainActor suspends here --- UI stays responsive ---
        let (result, sessionByCard, cachedLinks) = try await gatherReconciliationData(inputs: inputs)
        // --- Back on MainActor ---

        // Apply cached links if state was empty
        if let cachedLinks, state.links.isEmpty {
            for link in cachedLinks {
                state.links[link.id] = link
            }
        }

        // Invalidate cached chains for changed/lost session associations
        for (cardId, newSessionId) in sessionByCard {
            if state.sessionIdByCardId[cardId] != newSessionId {
                state.chainByCardId[cardId] = nil
            }
        }
        for cardId in state.sessionIdByCardId.keys {
            if sessionByCard[cardId] == nil {
                state.chainByCardId[cardId] = nil
            }
        }
        for (cardId, sessionId) in sessionByCard {
            state.sessionIdByCardId[cardId] = sessionId
        }

        dispatch(.reconciled(result))
    } catch {
        dispatch(.setError(error.localizedDescription))
        dispatch(.setLoading(false))
    }
}
```

**Step 2: Build**

Run: `cd ~/Playground/Development/claudeboard && swift build 2>&1 | tail -10`
Expected: Build succeeded. The old reconcile body is fully replaced.

**Step 3: Run all tests**

Run: `cd ~/Playground/Development/claudeboard && swift test 2>&1 | tail -20`
Expected: All tests pass. Behavior is identical — only execution context changed.

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "perf: move reconciliation I/O off MainActor

reconcile() now snapshots state, delegates heavy I/O (session discovery,
tmux, hook events, PID checks, activity polling) to a nonisolated method
that runs on the cooperative thread pool, then dispatches results back on
MainActor. Eliminates 3-10 second UI freezes during cache busts."
```

---

### Task 4: Manual verification — deploy and test

**Files:** None (runtime verification)

**Step 1: Deploy**

Run: `cd ~/Playground/Development/claudeboard && make deploy`
Expected: Build succeeds, old instance killed, new instance launched.

**Step 2: Verify no freeze on app switch**

1. Switch to another app (e.g. Finder or Terminal)
2. Wait 10-15 seconds (let Claude Code sessions write to .jsonl files)
3. Switch back to ClaudeBoard
4. UI should remain responsive — no freeze

**Step 3: Check logs for timing**

Run: `grep "TOTAL" ~/.kanban-code/logs/kanban-code.log | tail -5`
Expected: Times still show in logs (now labeled "TOTAL (background)"), confirming background execution. UI was never blocked.

**Step 4: Commit + push**

```bash
git push
```
