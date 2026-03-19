# Direct Launch — Skip Confirmation Dialog

**Date**: 2026-03-19
**Status**: Approved

## Problem

When pressing Play on a card or creating a new task, a `LaunchConfirmationDialog` popup appears asking the user to confirm/edit the prompt, toggle permissions, and review the command. This adds friction — the user wants instant launch, matching how Quick Launch already works.

## Design

Remove `LaunchConfirmationDialog` entirely. All launch and resume actions execute immediately with default settings.

### Changes

| File | Change |
|------|--------|
| `ContentView.swift` | Remove `LaunchConfig` struct, `@State launchConfig`, `.sheet(item: $launchConfig)` block |
| `ContentView.swift` | Add `@AppStorage("dangerouslySkipPermissions")` to ContentView (currently only in the dialog) |
| `ContentView.swift` → `startCard()` | Call `executeLaunch()` directly instead of building `LaunchConfig` |
| `ContentView.swift` → `resumeCard()` | Call `executeResume()` directly instead of building `LaunchConfig` |
| `NewTaskDialog.swift` → `submitForm()` | Pass `startImmediately: true` so card launches right after creation |
| `LaunchConfirmationDialog.swift` | Delete file |

### What's preserved

- `dangerouslySkipPermissions` persists via `@AppStorage` — uses last-saved value.
- Prompt is already set at card creation time (NewTaskDialog or Quick Launch).

### What's dropped

- Per-launch prompt editing (prompt is set at creation time).
- Per-launch command override (never used in practice).
- Per-launch permissions toggle (uses persisted value).

### Behavior after change

- **Play button**: instant launch, no dialog
- **Resume button**: instant resume, no dialog
- **Create task**: creates card AND launches immediately
- **Quick Launch**: unchanged (already direct)
