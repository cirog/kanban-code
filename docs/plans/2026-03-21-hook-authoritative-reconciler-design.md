# Hook-Authoritative Reconciler Redesign

## Problem

Session-to-card linking has two competing codepaths that create duplicates:

1. **Hook path** (event-driven): `SessionStart` hook fires → `resolveLink()` writes
   session link to SQLite via `CoordinationStore.addSessionPath()`. Does NOT update
   in-memory `AppState`. Correct signal (tmux name contains card ID).

2. **Reconciler path** (polling, ~5s): reads from in-memory `AppState` (not SQLite) →
   `CardReconciler.reconcile()` with 6 heuristic matching strategies → dispatches
   `.reconciled` → merge logic with `isLaunching`/`updatedAt` protection.

The hook writes to SQLite, the reconciler reads from memory. The hook's write is
invisible to the reconciler. Result: reconciler creates duplicate cards, old sessions
hijack managed cards via heuristic matching, slug dedup merges wrong cards together.

Five days of patches (name-to-slug, solo project path, tmux path disambiguation)
addressed symptoms. The root cause is two codepaths competing to answer the same
question: "which card does this session belong to?"

## Design Principle

**The hook is the single authority for linking sessions to managed cards.**

The hook already has the perfect signal: the tmux session name contains the card ID
(`ciro-card_3BF58La...`). This is deterministic — zero ambiguity. The reconciler
should never try to answer this question for managed cards.

## Architecture

### Two card types, same entity

All cards are `Link` entities. The difference is how they get their session link:

| | Managed Card | Discovered Card |
|---|---|---|
| Created by | User (double-click, quick launch) | Reconciler (unmatched session) |
| Session linked by | Hook (`SessionStart`) | Reconciler (only for unmatched sessions) |
| Has terminal | Yes (tmux) | No |
| Column movement | Activity-driven | Activity-driven |
| Archive behavior | Kills session + tmux | Kills session (no tmux to kill) |
| Source | `.manual` / `.todoist` | `.discovered` |

### Session linking flow

**Managed cards (created in ClaudeBoard):**

```
User creates card → dispatch(.createCard) → card in AppState with tmuxLink, no sessionLink
    → tmux launches claude → hook fires SessionStart
    → processHookEvents() → dispatch(.hookSessionLinked(cardId, sessionId, path))
    → reducer sets sessionLink on card in AppState
    → next reconciler cycle sees card already has sessionLink → skips matching
```

The new action `.hookSessionLinked` writes to **in-memory AppState** (the source of
truth). The reconciler sees the link immediately — no race, no SQLite/memory split.

**Discovered cards (external sessions):**

```
Reconciler discovers session → no card has this sessionId → no managed card claims it
    → reconciler creates new Link(source: .discovered, sessionLink: ..., tmuxLink: nil)
    → normal card, just no terminal
```

Discovered cards never interfere with managed cards because the reconciler only
creates cards for **truly unmatched** sessions (no card in AppState has this sessionId).

### What the reconciler does (after redesign)

1. **Discover sessions** — scan `~/.claude/projects/` (unchanged)
2. **Update activity** — for cards that already have a sessionLink, update lastActivity
3. **Create discovered cards** — for sessions not linked to any card, create new card
   with `source: .discovered`
4. **Clean dead tmux links** — remove stale tmux references (unchanged)
5. **Update columns** — activity → column assignment (unchanged)

### What the reconciler stops doing

- **Heuristic matching** — all 6 strategies in `findCardForSession()` eliminated
- **Slug dedup** — no more duplicates to merge
- **isLaunching guards** — no race to protect against
- **Preserve-vs-merge logic** — no competing writes to reconcile

### Context continuation (slug chaining)

When Claude Code continues a conversation (new sessionId, same slug), the hook fires
`SessionStart` in the same tmux. The hook resolves the tmux name → card, dispatches
`.hookSessionLinked` with the new sessionId. The card's session link updates
atomically. No heuristics needed.

For discovered cards (no tmux), context continuation creates a new unmatched session.
The reconciler creates a new discovered card. The old one goes stale → Done. This is
acceptable: discovered cards are lightweight and auto-cleanup handles old ones.

## Changes

### New

- `Action.hookSessionLinked(cardId: String, sessionId: String, path: String?)` — new
  reducer action. Sets `sessionLink` on the card in AppState. Clears `isLaunching`.

### Modified

- **`BackgroundOrchestrator.processHookEvents()`** — on `SessionStart`, resolve card
  via tmux name, dispatch `.hookSessionLinked` instead of writing to SQLite directly.
  Remove `resolveLink()` (the SQLite-based resolution function).

- **`CardReconciler.reconcile()`** — simplify to:
  1. Build set of all sessionIds already linked to cards
  2. For each discovered session: if sessionId in set → update lastActivity on existing
     card. If not → create new discovered card.
  3. Clean dead tmux links (unchanged logic).
  Delete: `findCardForSession()`, slug dedup (section B), all heuristic matching.

- **`BoardStore` reducer `.reconciled`** — simplify merge:
  1. For each reconciled link: if card exists in AppState with newer `updatedAt`, keep
     AppState version. Otherwise take reconciled version.
  2. Add new discovered cards.
  Delete: `isLaunching` preservation logic, `preservedIds` tracking.

- **`Link`** — remove `isLaunching` field. No longer needed.

### Deleted

- `CardReconciler.findCardForSession()` — all 6 heuristic strategies
- `CardReconciler.slugify()` — no longer needed
- Slug dedup block (section B of `reconcile()`)
- `BackgroundOrchestrator.resolveLink()` — replaced by hook dispatch
- `CoordinationStore.addSessionPath()` — hook no longer writes to SQLite directly
- `CoordinationStore.findBySlug()` — no longer needed for resolution
- `CoordinationStore.findByTmuxSessionName()` — no longer needed for resolution

### Tests

- **Delete**: reconciler heuristic matching tests (sessionId-match tests stay since
  that's now "is this session already linked?")
- **Add**: hook-authoritative linking tests:
  - SessionStart hook → card gets sessionLink in AppState
  - Context continuation → card's sessionLink updates to new sessionId
  - External session → discovered card created
  - Managed card not hijacked by stale session
  - Archive discovered card → kills session process

## Migration

No data migration needed. Existing cards in SQLite keep their session links. On next
app start, `AppState` loads from SQLite (current behavior). The new reconciler sees
existing session links and respects them. The hook takes over linking for new sessions.

## Risk

- **External sessions that share a tmux name with a card**: impossible — ClaudeBoard
  generates unique tmux names with the card ID embedded.
- **Hook doesn't fire**: if the hook system fails, managed cards won't get session
  links. Sessions would appear as discovered cards. User sees duplicates but can
  archive the discovered one. Degraded but functional.
- **App restart during active session**: on restart, `processHookEvents()` replays old
  `SessionStart` events (existing behavior, line 110-137). This re-links sessions to
  cards via tmux name. No change needed.
