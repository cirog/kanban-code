# Aggressive Pruning — Fix CPU Spikes

**Date:** 2026-04-02
**Status:** Approved
**Supersedes:** `2026-04-02-reconcile-off-mainactor-design.md` (wrong diagnosis)

## Problem

ClaudeBoard causes periodic CPU spikes that freeze the machine for 3-4 seconds.

### Root Cause Analysis

Initial hypothesis (MainActor blocked by discovery I/O) was disproven by TDD —
Swift concurrency already suspends MainActor at await points.

**Actual root cause: unbounded data growth.**

1. **1,150 cards in memory** — AutoCleanup prunes on DB load, but the reconciler
   immediately re-creates cards for all 1,047 sessions on disk. Steady-state is
   ~1,150 cards that are never truly pruned.

2. **SwiftUI diffing on 1,100 Done cards** — every `dispatch()` triggers
   `rebuildCards()` (1,150 ClaudeBoardCard allocations) → SwiftUI re-evaluates
   `cards(in: .done)` (filter + sort + ForEach diff on ~1,100 items). Cold-start
   reconcile creates ~1,000 cards in one dispatch → 0→1,000 diff.

3. **383MB log file** — 3.8M entries, never rotated. Each log write opens a
   FileHandle, seeks to 383MB offset, writes, closes. Bursts of 1,000+ writes
   during reconcile create I/O storms. `ISO8601DateFormatter()` created fresh per
   log entry (expensive ICU initialization).

4. **8,722 hook events** — accumulated indefinitely, iterated per reconcile.

## Solution

**Delete everything older than 3 days that isn't actively used.** Plus log rotation.

### 1. Session Age Filter in Discovery

**File:** `ClaudeCodeSessionDiscovery.swift`

Skip .jsonl files whose mtime is older than 3 days. Don't parse them, don't
return them. This is the single highest-impact change — it reduces session count
from ~1,047 to the handful of recently active sessions.

```swift
let cutoff = Date.now.addingTimeInterval(-3 * 24 * 3600)
// In the jsonl scanning loop:
guard mtime > cutoff else { continue }
```

### 2. AutoCleanup After Every Reconcile

**File:** `BoardStore.swift`

Run `AutoCleanup.clean()` on the reconciled links before dispatching, not just on
DB load. Change `maxAgeHours` from 24 to 72 (3 days).

### 3. AutoCleanup: Remove Source Filter

**File:** `AutoCleanup.swift`

Currently only prunes `source == .discovered`. Change to prune ALL Done cards
older than 3 days regardless of source. A card that's been done for 3 days is
done.

### 4. Hook Event Pruning

**File:** `HookEventStore.swift`

When reading all stored events, discard events older than 3 days. Optionally
rewrite the file periodically to reclaim space.

### 5. Log Rotation + Performance

**File:** `KanbanCodeLog.swift`

- **Persistent FileHandle** — open once, write many, close on deinit. Eliminates
  1,000+ open/seek/close cycles per burst.
- **Cached ISO8601DateFormatter** — one instance, reused.
- **Log rotation** — on startup and when file exceeds 10MB, rotate current log to
  `.1` (delete existing `.1`). Caps disk usage at ~20MB.

## Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| Cards in memory | ~1,150 | ~20-50 |
| Sessions scanned | ~1,047 | ~20-50 |
| Discovery time | 50ms-9.6s | <10ms |
| Log file size | 383MB | ≤10MB |
| Log write cost | open+seek(383MB)+close | write to open handle |
| Hook events | 8,722 | ~200 |
| SwiftUI diff (Done) | ~1,100 items | ~20 items |

## Scope

**Files modified (5):**
- `ClaudeCodeSessionDiscovery.swift` — 3-day mtime filter
- `AutoCleanup.swift` — remove source filter, 72h age
- `BoardStore.swift` — run cleanup after reconcile
- `HookEventStore.swift` — 3-day event pruning
- `KanbanCodeLog.swift` — persistent handle, cached formatter, rotation

**Unchanged:** Reducer, CardReconciler, views, tests (behavior identical for
recent sessions, old sessions simply not loaded).
