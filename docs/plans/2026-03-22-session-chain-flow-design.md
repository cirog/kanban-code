# Session Chain Flow Reconstruction — Design

**Date**: 2026-03-22
**Status**: Approved

## Problem

The reconciler reliably associates sessions to cards via the `session_links` table (tmux-authoritative matching). However, the History and Prompts tabs only display the *current* session. If a conversation spans multiple sessions (via `--resume`, `/clear`, compaction, or new launches), earlier sessions are invisible.

- `CardDetailView.hasChainedSessions` is hardcoded `false`
- `allSessionPaths` returns a single path
- No chain reconstruction exists anywhere in the UI

## Solution

Introduce a `SessionChain` domain entity that reconstructs the full ordered history of sessions belonging to a card. Wire it through the Elm architecture (Action → Effect → AppState) so views consume it without DB access.

### Domain Model

**`SessionChain`** — ordered list of `ChainSegment`s for a card.

**`ChainSegment`** — one session in the chain:
- `id` (sessionId), `path` (JSONL file), `matchedBy` (tmux/discovered)
- `firstTimestamp`, `lastTimestamp` — parsed from first/last JSONL turns (ordering key + gap calculation)
- `slug` — for resume detection
- `transitionReason` — best-effort enum:
  - `.initial` — first session in chain
  - `.resumed(gap)` — same slug as previous session
  - `.interrupted(gap)` — previous session ended with "[Request interrupted by user]"
  - `.newSession(gap)` — fallback (different slug or no slug)

### Transition Reason Detection (Best-Effort)

| Reason | Signal | Reliability |
|--------|--------|-------------|
| Resumed | Same slug as previous segment | Medium (~18% slug coverage) |
| Interrupted | Previous JSONL ends with "[Request interrupted by user]" | Very high |
| New session | Fallback — no slug match | Default |
| Time gap | `segment[n].firstTimestamp - segment[n-1].lastTimestamp` | 100% |

When slug is absent, falls back to "New session" with gap duration. This is acceptable — the gap duration is the most useful context regardless.

### Data Flow

```
session_links (DB)
      ↓  CoordinationStore.chainSegments(forCardId:limit:)
[raw rows: sessionId, path, matchedBy]
      ↓  SessionChainBuilder.build() — read first/last timestamps, sort, detect transitions
SessionChain (domain entity)
      ↓  Action.chainLoaded(cardId, SessionChain)
AppState.chainByCardId[cardId]
      ↓
History tab / Prompts tab (consume)
```

**Lazy loading**: Chains are only built when a card is selected and History or Prompts tab is opened. Not during reconciliation. Cached in `AppState.chainByCardId` and invalidated when `sessionIdByCardId` changes for that card.

### History Tab Changes

- **Segmented timeline**: Loads most recent 5 sessions by default. Turns from all loaded sessions are concatenated and re-indexed for scroll/search continuity.
- **Visual dividers**: Between sessions, a styled separator shows:
  - Transition reason (when detectable): "Resumed", "Interrupted", "New session"
  - Gap duration: "2h 15m gap", "1d gap"
  - Session start time
  - Example: `── Resumed · 2h gap · Mar 21, 14:30 ──`
- **Load earlier sessions**: Button at top if `chain.totalSegments > loaded count`. Triggers an Effect to load the next batch.
- **Live reload**: Unchanged — still watches current session's JSONL. New turns append to the end of the timeline.
- **Existing features preserved**: Search, pagination within sessions, scroll state, checkpoint mode.

### Prompts Tab Changes

- **Markdown rendering**: Replace plain `Text()` views with WKWebView + Dracula theme (same renderer as History tab / HistoryPlusView). User prompts rendered as styled markdown.
- **Grouped by session**: Each session is a collapsible section. Section header shows session start time + transition reason.
- **Load recent 5 + load-more**: Same pagination as History tab.
- **Copy All**: Updated to include prompts from all loaded sessions.

### What Doesn't Change

- **Reconciler** — untouched; already builds `session_links` correctly
- **Card-session association** — same `sessionIdByCardId` for current/active session
- **Board view, toolbar, all other tabs** — no changes
- **DB schema** — `session_links` table already has everything needed (session_id, link_id, path)

### Performance

- Chain resolution reads `session_links` (indexed on `link_id`) + one first-line parse per JSONL file
- Capped at 5 sessions per load — bounded I/O regardless of chain length
- Chain cached in AppState — no re-computation on tab switches
- Last-line check for interrupted detection: single seek to end of file

### New Files

- `Sources/ClaudeBoardCore/Domain/Entities/SessionChain.swift` — ChainSegment, TransitionReason, SessionChain
- `Sources/ClaudeBoardCore/UseCases/SessionChainBuilder.swift` — pure function: raw DB rows → sorted chain with transition reasons

### Modified Files

- `CoordinationStore.swift` — add `chainSegments(forCardId:limit:)` query
- `BoardStore.swift` — add `Action.loadChain`/`.chainLoaded`, `Effect.loadChain`, `AppState.chainByCardId`
- `CardDetailView.swift` — update `loadHistory()`, `loadPrompts()`, `allSessionPaths` to use chain; add session divider views
- `HistoryPlusView.swift` or new `PromptsPlusView.swift` — WKWebView markdown renderer for prompts tab
