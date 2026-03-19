# Tmux-Based Session Fallback Matching

**Date**: 2026-03-19
**Status**: Approved

## Problem

When Claude Code breaks its slug contract (generates a new slug instead of preserving the parent's during plan mode exit or context split), the reconciler creates an orphan card. The session is still running inside the original card's tmux terminal, but ClaudeBoard can't see that connection.

This causes: orphan cards, stale history/summary on the original card, incorrect column states.

Root cause: Claude Code bug (GitHub issue #26832). ClaudeBoard's slug-based chaining is correct by design — this is a defensive hardening.

## Solution

Add **Priority 2.5** match in `CardReconciler.findCardForSession()`: after "project+tmux (no sessionLink)" and before "prompt body".

**Rule**: If a newly discovered session has a `projectPath` that matches a card which has a live tmux session, chain the new session to that card — regardless of slug. Aggressive mode: always chain when project+tmux match, no staleness check.

## Match Priority (after change)

1. Exact sessionId (already linked)
2. Project path + tmux, card has NO sessionLink (launch flow)
3. **NEW: Project path + tmux, card HAS sessionLink (tmux fallback)** — chain newest session
4. Prompt body match (manual card)
5. Slug match (conversation continuity)

## Changes

| File | Change |
|------|--------|
| `CardReconciler.swift` → `findCardForSession()` | Add Priority 2.5: match by project+tmux even when card has sessionLink |
| `CardReconciler.swift` → main loop | When Priority 2.5 matches, chain session (same as slug chain logic at lines 91-109) |

## Edge Cases

- **Two cards in same project with live tmux**: Pick the card whose tmux session name appears in the same project path. If ambiguous, skip (fall through to prompt/slug).
- **Subagent sessions**: Run in separate tmux sessions — won't match. Safe.
- **User starts new conversation in new terminal**: Different tmux name → no match → new card. Correct.
- **Old discovered sessions**: Sessions are processed newest-first (sorted by modifiedTime desc in discovery). The first match wins, preventing old sessions from overriding.

## What stays the same

- All other match priorities unchanged
- History, summary, prompt display code unchanged — they read from `sessionLink.sessionPath` which gets updated by chaining
- `previousSessionPaths` accumulation unchanged
