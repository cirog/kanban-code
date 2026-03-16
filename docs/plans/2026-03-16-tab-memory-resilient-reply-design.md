# Tab Memory + Resilient Reply Design

**Date**: 2026-03-16
**Status**: Approved

## Problems

1. **Tab resets on card re-selection**: Clicking away from a card and back always resets to Terminal tab, losing the user's tab context.
2. **Reply tab loses content**: Switching cards recreates the WKWebView, losing the rendered reply. Overly complex caching logic causes race conditions with "Waiting for reply..." placeholders.

## Solution

### Part 1: Tab Memory per Card

Add `lastTab: String?` to `Link`. Persist tab selection when user switches tabs. Restore on card open.

- Save: `handleTabChange()` dispatches `.setLastTab(cardId, tab)`
- Load: `defaultTab(for:)` checks `link.lastTab` first
- Scope: Terminal, Reply, History only

### Part 2: Resilient Reply Content

Simplify ReplyTabView: always fetch the latest complete reply from the transcript on appear. Remove caching complexity.

- Always load on `makeNSView` — fresh read every time
- Only show "Waiting for reply..." for sessions with zero assistant turns
- Remove `lastRenderedTurnIndex` caching — WKWebView is recreated per card anyway
- Keep `refreshTrigger` for live updates while on the tab

## Scope Exclusions

- No tab history stack
- No animation on restore
