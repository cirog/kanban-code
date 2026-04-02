# Move Reconciliation Off MainActor

**Date:** 2026-04-02
**Status:** Approved

## Problem

`BoardStore` is `@MainActor`. Its `reconcile()` method performs heavy I/O that
blocks the main thread, freezing the entire UI:

- `discoverSessions()` scans 1,369 .jsonl files across 604MB — up to **10.27s**
  on cache bust (observed 2026-04-02 07:01)
- `tmuxAdapter?.listSessions()` shells out to tmux
- `hookEventStore.readAllStoredEvents()` reads 2.7MB of hook events
- `coordinationStore.allSessionAssociations()` SQLite query
- `ProcessChecker.isAlive()` for ~272 PIDs
- `activityDetector.activityState()` file stat per active session

Normal ticks take ~250ms; cache busts (app activate after background, sleep wake,
new sessions) spike to 2-10s. The user experiences this as a full system freeze
because the MainActor cannot process any UI events during reconciliation.

**Trigger pattern:** Switch from another app (e.g. Excel) back to ClaudeBoard →
`didBecomeActiveNotification` → `store.reconcile()` → directory mtimes changed
while backgrounded → full re-scan on MainActor → freeze.

### Evidence from logs

```
[07:01:24] discoverSessions: 9.639s (1043 sessions)  ← cache bust
[07:01:24] TOTAL: 10.274s
[07:01:56] discoverSessions: 0.050s (1043 sessions)  ← cache warm
[07:01:56] TOTAL: 0.399s
```

## Solution

Split `reconcile()` into two phases:

### Phase 1 — Background data gathering (`nonisolated`)

New `nonisolated private func gatherReconciliationData(...)` that:
1. Receives a value-type snapshot of state inputs (configured projects, excluded
   paths, existing links, deleted session/card IDs)
2. Runs all heavy I/O on the cooperative thread pool:
   - `discovery.discoverSessions()`
   - `tmuxAdapter?.listSessions()`
   - `hookEventStore.readAllStoredEvents()`
   - `coordinationStore.allSessionAssociations()`
   - `CardReconciler.reconcile()` (pure function)
   - `ProcessChecker.isAlive()` loop
   - `activityDetector.activityState()` loop
3. Returns a result struct with everything the reducer needs

### Phase 2 — MainActor dispatch (stays `@MainActor`)

`reconcile()` remains `@MainActor`. It:
1. Snapshots state inputs (cheap dictionary copies)
2. `await`s `gatherReconciliationData(inputs)` — **suspends MainActor**, UI stays
   responsive
3. Dispatches `.reconciled(result)` on MainActor

### Data race safety

- `ClaudeCodeSessionDiscovery` is `@unchecked Sendable` with internal mutable
  caches, designed for single-caller access. The existing `isReconciling` guard
  prevents concurrent calls.
- `CoordinationStore` is an `actor` — already safe for cross-isolation calls.
- `HookEventStore` is an `actor` — already safe.
- `ActivityDetector` is an `actor` — already safe.
- `CardReconciler.reconcile()` is a pure static function.
- `ProcessChecker.isAlive()` is a stateless static function.

No new concurrency primitives needed.

## Scope

**Files modified:** `BoardStore.swift` only

**Unchanged:**
- `BoardStore` class declaration (`@MainActor @Observable`)
- `Reducer`, `Action`, `Effect`
- `CardReconciler`, `BackgroundOrchestrator`
- `ContentView` activation handler (still calls `store.reconcile()`)
- All existing tests (behavior identical, only execution context changes)

## Not in scope

- Log rotation (383MB log file)
- Hook event compaction (8,722 events)
- Session/card count pruning (1,150 cards)

These are real issues but not causing the freeze. Can be addressed separately.
