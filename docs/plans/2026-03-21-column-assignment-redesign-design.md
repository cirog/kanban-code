# Column Assignment Redesign

**Date**: 2026-03-21
**Status**: Approved

## Problem

Three bugs share the same root cause — `AssignColumn` is a binary classifier in a system that produces a spectrum of activity states:

1. **Cold start**: On restart, no hook events exist in memory. Activity detector returns `.stale` for every session. AssignColumn treats this as "not active" → cards move to Done.
2. **Normal use disappearances**: AssignColumn only checks `.activelyWorking`. States like `.needsAttention`, `.idleWaiting`, `.ended` all fall through to the default `.done`. The only thing keeping cards in Waiting is `hasLiveTmux` — if tmux is absent or dead, cards go to Done.
3. **Manual override clearing**: The `.reconciled` handler clears user column pins when any non-stale activity arrives, then AssignColumn runs without protection and demotes cards to Done.

## Design Principle

**Cards never auto-demote to Done.** Only explicit user action (drag to Done, archive button, delete) moves cards off the board. The system can promote cards (backlog → waiting → inProgress) but never demotes.

## Change 1: AssignColumn v2

New mapping uses the full activity spectrum:

```
Priority 1: Live process
  .activelyWorking           → .inProgress

Priority 2: User intent
  manualOverrides.column     → keep current
  manuallyArchived           → .done

Priority 3: Activity-driven
  .needsAttention            → .waiting
  .idleWaiting               → .waiting
  .ended                     → .waiting
  .stale                     → .waiting
  hasLiveTmux                → .waiting

Priority 4: No data (cold start, race)
  nil activityState          → NO CHANGE (return link.column)

Priority 5: Classification (new cards only)
  manual/todoist, no session → .backlog
  discovered (new)           → .done
```

Key: `nil` activity means "can't reason about this card" → preserve whatever column it's in. This directly fixes cold start.

## Change 2: Remove Manual Override Clearing

Delete the override-clearing blocks in both `.reconciled` and `.activityChanged` reducer cases. Manual overrides are only cleared by:

- User dragging the card to a different column
- `launchCard` / `resumeCard` actions (already clear overrides)

User intent is sacred — background processes don't undo it.

## Change 3: AutoCleanup Scoped to Discovered Cards

Since Done is now user-explicit, AutoCleanup's 24h removal only applies to `source == .discovered` cards. User-created, hook-linked, and Todoist cards in Done are kept indefinitely.

## Files Changed

| File | Change |
|------|--------|
| `AssignColumn.swift` | New mapping: activity spectrum → columns, `nil` → preserve current |
| `BoardStore.swift` (.reconciled) | Remove override-clearing block |
| `BoardStore.swift` (.activityChanged) | Remove override-clearing for backlog |
| `AutoCleanup.swift` | Filter only `source == .discovered` for 24h removal |

## Not Changed

- `CardReconciler.swift` — still creates discovered cards as `.done`, still updates metadata
- `UpdateCardColumn.swift` — still wraps AssignColumn, no change
- `BackgroundOrchestrator.swift` — hook processing unchanged
- `CoordinationStore.swift` — persistence unchanged
- `isLaunching` lock — still needed during launch window
- `preservedIds` logic — still needed for race protection
