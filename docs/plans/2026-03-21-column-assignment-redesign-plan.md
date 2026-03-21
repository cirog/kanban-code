# Column Assignment Redesign — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix three column-assignment bugs by mapping the full activity spectrum to columns, removing auto-archival, and scoping AutoCleanup to discovered cards.

**Architecture:** `AssignColumn` becomes a complete mapping of all 5 `ActivityState` values + `nil` to columns. `nil` (cold start / no data) preserves the existing column. Manual override clearing is removed from the reconciliation reducer. AutoCleanup's 24h expiry is scoped to `source == .discovered` only.

**Tech Stack:** Swift 6.2, Swift Testing framework, ClaudeBoardCore library

---

### Task 1: Update AssignColumn Tests

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/SimplifiedAssignColumnTests.swift`

**Step 1: Update existing tests that expect `.done` for activity states**

The following tests currently expect `.done` — they must change to `.waiting`:

```swift
// REPLACE the "Removed behaviors" section (lines 111-149) with:

// MARK: - Priority 3: Activity-Driven (no live process, no override)

@Test func noProcess_needsAttention_goesToWaiting() {
    let link = Link(source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: .needsAttention, hasLiveTmux: false)
    #expect(result == .waiting)
}

@Test func noProcess_idleWaiting_goesToWaiting() {
    let link = Link(source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: .idleWaiting, hasLiveTmux: false)
    #expect(result == .waiting)
}

@Test func noProcess_ended_goesToWaiting() {
    let link = Link(source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: .ended, hasLiveTmux: false)
    #expect(result == .waiting)
}

@Test func noProcess_stale_goesToWaiting() {
    let link = Link(source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: .stale, hasLiveTmux: false)
    #expect(result == .waiting)
}
```

**Step 2: Add new tests for nil-preserves-column behavior**

Add these tests to the end of the file (before the closing brace):

```swift
// MARK: - Priority 4: No Data (cold start) — Preserve Column

@Test func nilActivity_noTmux_preservesWaiting() {
    let link = Link(column: .waiting, source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
    #expect(result == .waiting)
}

@Test func nilActivity_noTmux_preservesInProgress() {
    let link = Link(column: .inProgress, source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
    #expect(result == .inProgress)
}

@Test func nilActivity_noTmux_preservesDone() {
    let link = Link(column: .done, source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
    #expect(result == .done)
}

@Test func nilActivity_noTmux_preservesBacklog() {
    let link = Link(column: .backlog, source: .manual)
    let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
    #expect(result == .backlog)
}

// MARK: - Priority 5: Classification (new cards, nil activity)

@Test func noProcess_discoveredCard_nilActivity_preservesDone() {
    // Discovered cards start as .done (set by CardReconciler), nil preserves that
    let link = Link(column: .done, source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
    #expect(result == .done)
}
```

**Step 3: Update the existing `noProcess_default_goesToDone` test**

This test (line 105-109) currently creates a discovered link with default column and `nil` activity. With the new behavior, `nil` preserves the column. Since `Link(source: .discovered)` defaults to `.done` column, the test still passes but rename for clarity:

```swift
@Test func noProcess_discoveredDefault_preservesDone() {
    let link = Link(source: .discovered)
    let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
    #expect(result == .done)
}
```

**Step 4: Remove the `noProcess_recentActivity_goesToDone` and scheduled/summary tests**

Delete lines 127-149 (`noProcess_recentActivity_goesToDone`, `noProcess_scheduledTask_goesToDone`, `noProcess_summarySession_goesToDone`). These tested the old default-done behavior for specific card types. They're replaced by the activity-driven tests above.

**Step 5: Run tests to verify they fail**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter SimplifiedAssignColumnTests 2>&1`

Expected: 4 FAIL (needsAttention, idleWaiting, ended, stale now expect `.waiting` but get `.done`), 4 FAIL (nil-preserves tests expect current column but get `.done` or `.backlog`)

**Step 6: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/SimplifiedAssignColumnTests.swift
git commit -m "test: update AssignColumn tests for activity spectrum mapping"
```

---

### Task 2: Implement AssignColumn v2

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/AssignColumn.swift`

**Step 1: Rewrite AssignColumn.assign()**

Replace the entire body of `AssignColumn` (lines 1-49):

```swift
import Foundation

/// Determines which Kanban column a link should be in based on its state.
///
/// Priority layers:
///   1. Live process (.activelyWorking) — always inProgress
///   2. User intent (manual override, archived) — respected
///   3. Activity-driven — any known activity state → waiting
///   4. No data (nil) — preserve current column (cold start safety)
///   5. Classification — backlog for unstarted tasks, live tmux → waiting
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil,
        hasLiveTmux: Bool = false
    ) -> ClaudeBoardColumn {
        // --- Priority 1: Active work always shows in progress ---
        if activityState == .activelyWorking {
            return .inProgress
        }

        // --- Priority 2: Live tmux process → waiting ---
        if hasLiveTmux {
            return .waiting
        }

        // --- Priority 3: User intent ---
        if link.manualOverrides.column {
            return link.column
        }

        if link.manuallyArchived {
            return .done
        }

        // --- Priority 4: Activity-driven (any known state → waiting) ---
        if let activity = activityState {
            switch activity {
            case .activelyWorking:
                return .inProgress // Already handled above, but exhaustive
            case .needsAttention, .idleWaiting, .ended, .stale:
                return .waiting
            }
        }

        // --- Priority 5: No data (nil) — preserve current column ---
        // On cold start or race conditions, we have no activity data.
        // Don't move cards we can't reason about.

        // Exception: unstarted tasks stay in backlog
        if (link.source == .manual || link.source == .todoist) && link.sessionLink == nil {
            return .backlog
        }

        return link.column
    }
}
```

**Step 2: Run tests to verify they pass**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter SimplifiedAssignColumnTests 2>&1`

Expected: ALL PASS

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/AssignColumn.swift
git commit -m "feat: AssignColumn v2 — activity spectrum mapping, nil preserves column"
```

---

### Task 3: Update AutoCleanup Tests

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/AutoCleanupTests.swift`

**Step 1: Update `removesOldDoneCards` to use discovered source and add non-discovered test**

Replace the entire test file:

```swift
import Testing
import Foundation
@testable import ClaudeBoardCore

struct AutoCleanupTests {
    @Test func removesOldDoneCards_discoveredOnly() {
        let oldDiscovered = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600), // 25h ago
            source: .discovered
        )

        let oldManual = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600), // 25h ago
            source: .manual
        )

        let oldHook = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600), // 25h ago
            source: .hook
        )

        let oldTodoist = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600), // 25h ago
            source: .todoist
        )

        let recentDiscovered = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-12 * 3600), // 12h ago
            source: .discovered
        )

        let waiting = Link(
            column: .waiting,
            updatedAt: Date.now.addingTimeInterval(-72 * 3600), // 3 days ago
            source: .discovered
        )

        let result = AutoCleanup.clean(links: [oldDiscovered, oldManual, oldHook, oldTodoist, recentDiscovered, waiting])

        #expect(result.count == 5) // only oldDiscovered removed
        #expect(!result.contains(where: { $0.id == oldDiscovered.id }))
        #expect(result.contains(where: { $0.id == oldManual.id }))
        #expect(result.contains(where: { $0.id == oldHook.id }))
        #expect(result.contains(where: { $0.id == oldTodoist.id }))
        #expect(result.contains(where: { $0.id == recentDiscovered.id }))
        #expect(result.contains(where: { $0.id == waiting.id }))
    }

    @Test func capsAtMaxCards() {
        var links: [Link] = []
        for i in 0..<1100 {
            let link = Link(
                column: .done,
                updatedAt: Date.now.addingTimeInterval(-Double(i) * 60),
                source: .discovered
            )
            links.append(link)
        }

        let result = AutoCleanup.clean(links: links, maxCards: 1000)
        #expect(result.count == 1000)
    }

    @Test func keepsNonDoneCards_evenIfVeryOld() {
        let backlog = Link(
            column: .backlog,
            updatedAt: Date.now.addingTimeInterval(-30 * 86400), // 30 days ago
            source: .manual
        )
        let inProgress = Link(
            column: .inProgress,
            updatedAt: Date.now.addingTimeInterval(-30 * 86400),
            source: .discovered
        )
        let waiting = Link(
            column: .waiting,
            updatedAt: Date.now.addingTimeInterval(-30 * 86400),
            source: .discovered
        )

        let result = AutoCleanup.clean(links: [backlog, inProgress, waiting])
        #expect(result.count == 3) // none removed — only Done expires
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter AutoCleanupTests 2>&1`

Expected: `removesOldDoneCards_discoveredOnly` FAIL (currently removes all old Done cards regardless of source)

**Step 3: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/AutoCleanupTests.swift
git commit -m "test: AutoCleanup scoped to discovered source only"
```

---

### Task 4: Implement AutoCleanup Source Filter

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/AutoCleanup.swift`

**Step 1: Add source filter to the "Remove old Done cards" block**

Change line 28 from:
```swift
if link.column == .done && link.updatedAt < cutoff {
```
to:
```swift
if link.column == .done && link.source == .discovered && link.updatedAt < cutoff {
```

**Step 2: Run tests to verify they pass**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter AutoCleanupTests 2>&1`

Expected: ALL PASS

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/AutoCleanup.swift
git commit -m "fix: AutoCleanup only expires discovered cards after 24h"
```

---

### Task 5: Remove Manual Override Clearing from BoardStore

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`

**Step 1: Remove override-clearing block in `.reconciled` case**

Delete lines 885-894 (the block that clears `manualOverrides.column` when activity is non-stale or tmux is dead):

```swift
// DELETE THIS ENTIRE BLOCK:
                // Clear manual column override when we have definitive data.
                // Backlog is sticky — the user explicitly parked this card.
                if link.manualOverrides.column && link.column != .backlog {
                    if activity != nil && activity != .stale {
                        link.manualOverrides.column = false
                    } else if link.tmuxLink != nil && !hasLiveTmux {
                        link.tmuxLink = nil
                        link.manualOverrides.column = false
                    }
                }
```

**Step 2: Remove override-clearing in `.activityChanged` case**

Delete lines 932-934 (the block that clears manual backlog override on `.activelyWorking`):

```swift
// DELETE THIS BLOCK:
                // Clear manual backlog override when activity promotes the card
                if activity == .activelyWorking && link.manualOverrides.column && link.column == .backlog {
                    link.manualOverrides.column = false
                }
```

**Step 3: Run full test suite**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1`

Expected: ALL PASS. The override-clearing had no dedicated tests (it was implicit behavior).

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "fix: remove manual override clearing — user column pins are sacred"
```

---

### Task 6: Build and Deploy

**Step 1: Build**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1`

Expected: BUILD SUCCEEDED

**Step 2: Run full test suite one final time**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1`

Expected: ALL PASS

**Step 3: Deploy**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && make deploy 2>&1`

**Step 4: Push**

Run: `git push`
