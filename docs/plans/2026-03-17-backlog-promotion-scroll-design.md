# Backlog Auto-Promotion + Scroll-to-Bottom Design

**Date**: 2026-03-17
**Status**: Approved

## Problems

1. **Backlog cards ignore activity**: Cards manually placed in Backlog stay there even when Claude is actively working on them. The manual backlog override (line 14-16 in AssignColumn) runs before the `.activelyWorking` check (line 19), blocking auto-promotion.

2. **Reply/Prompts tabs start at top**: Neither the Reply tab (WKWebView) nor the Prompts tab (SwiftUI ScrollView) scroll to the bottom on appear. The most recent content is at the bottom, so users must scroll manually every time.

## Solution

### Part 1: Backlog Auto-Promotion

Reorder `AssignColumn.assign()` so `.activelyWorking` is checked **first**, before the manual backlog override:

```
1. activelyWorking → IN_PROGRESS (moved above backlog check)
2. manual backlog override → BACKLOG
3. ... rest unchanged
```

In the reducer's `activityChanged` handler: when a backlog card with manual override gets `.activelyWorking`, clear `manualOverrides.column` so it doesn't snap back to Backlog on next reconciliation.

After Claude finishes, the card follows the normal cycle: `.needsAttention` → Waiting. It stays in Waiting permanently until manually moved.

### Part 2: Scroll-to-Bottom

**Reply tab** (WKWebView): Add `window.scrollTo(0, document.body.scrollHeight)` in the JavaScript after `marked.parse()` renders content.

**Prompts tab** (SwiftUI ScrollView): Wrap in `ScrollViewReader`, add a bottom anchor, scroll to it on appear and when `promptTurns` changes.

## Scope Exclusions

- No "snap back to backlog" logic after activity ends
- No scroll position memory between tab switches
- No auto-scroll on live content updates (only on appear/load)
