# Session & Column Redesign

**Date**: 2026-03-21
**Status**: Draft (revised — supersedes original 3-change design)
**Reference**: [Claude Code Session Data Model](../reference/claude-session-data-model.md)

## Problem

Five observed problems trace to two root causes: (A) the session-to-card association
model is wrong, and (B) the column assignment logic is a binary classifier in a system
that produces a spectrum.

### Root Cause A: Session Association Model

The current system matches sessions to cards using project path as a fallback key, treats
null tmux as a valid match, and allows the same session to be linked to multiple cards.
This violates the theoretical data model where:

- **Tmux name** is the primary association key (contains card ID, immediate)
- **Slug** is the secondary key (deferred, cross-terminal)
- **Project path is never an association key** (too broad — `/Users/ciro` matches everything)
- **Null keys never match** (fall through to next level)
- **Session → card is N:1** (each session belongs to exactly one card)

Observed consequences:
- CB card accumulated 7 sessions: 6 scheduled tasks + 1 actual work session
- 3 sessions double-linked to both CB card and their own discovered cards
- CB card driven to `in_progress` by a graphiti-cleanup scheduled task

### Root Cause B: Column Assignment

`AssignColumn` only recognizes `.activelyWorking`. All other activity states (`.needsAttention`,
`.idleWaiting`, `.ended`, `.stale`) fall through to default `.done`. Combined with manual
override clearing, this causes cards to auto-archive.

Observed consequences:
- Cold start: no hook events → `.stale` → all cards to Done
- Normal use: session stops → `.needsAttention` → card to Done
- User drags card to Waiting → override cleared by background process → card to Done

## Design Principles

1. **Cards never auto-demote to Done.** Only explicit user action archives cards.
2. **Session lifecycle ≠ card lifecycle.** Sessions are ephemeral (new UUID on every
   /clear, resume, compact). A session ending is routine, not an archival signal.
3. **Null keys never match.** No tmux → fall through. No slug → fall through.
4. **Session ownership is exclusive.** One session belongs to one card. Always.
5. **User intent is sacred.** Background processes never override user column pins.
6. **Absence of data = preserve state.** "I don't know" → don't change.

---

## Change 1: Schema — Replace `session_paths` with `session_links`

### Drop

```sql
DROP TABLE session_paths;
```

### Create

```sql
CREATE TABLE session_links (
    session_id    TEXT PRIMARY KEY,
    link_id       TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
    matched_by    TEXT NOT NULL,  -- "tmux" | "slug" | "discovered"
    is_current    INTEGER NOT NULL DEFAULT 0,
    path          TEXT,
    created_at    TEXT NOT NULL
);

CREATE INDEX idx_sl_link ON session_links(link_id);
CREATE INDEX idx_sl_current ON session_links(link_id, is_current) WHERE is_current = 1;
```

### Key differences from old `session_paths`

| Property | Old `session_paths` | New `session_links` |
|----------|-------------------|-------------------|
| Primary key | `(link_id, session_id)` — allows M:N | `session_id` — enforces N:1 |
| Same session on 2 cards | Allowed (caused bug) | Impossible (PK constraint) |
| Reassignment | Insert second row | UPDATE existing row |
| Audit trail | None | `matched_by` records why |

### In-memory model changes

```swift
// DELETE: SessionLink struct (sessionId, sessionPath, slug, previousSessionPaths)
// The card's slug field (already on Link) becomes the primary association key.
// Current session is looked up from session_links table, never duplicated on Link.

// Link struct changes:
// - Remove: sessionLink: SessionLink?
// - Keep: slug (already exists as a field)
// - NO new fields. Current session is queried from session_links when needed.
//   The reconciler builds a transient sessionId-by-cardId index each cycle.
```

### Remove `override_tmux` column from `links`

```sql
ALTER TABLE links DROP COLUMN override_tmux;
-- Never used meaningfully. ManualOverrides.tmuxSession removed from Swift struct.
```

---

## Change 2: Reconciler — Association Hierarchy

`CardReconciler.reconcile()` uses the three-level hierarchy to match sessions to cards.

### Algorithm

```
Input:  discovered sessions (from disk scan)
        existing cards (from state)
        existing session_links (from DB)

For each discovered session:

  Step 1: Already owned?
    If session_links[session.id] exists → skip (already assigned)

  Step 2: Tmux match (immediate, strongest)
    If session has a tmux name (from hook events):
      Extract card ID from tmux name
      If card exists → INSERT session_links(session.id, card.id, "tmux")
      Continue

  Step 3: Slug match (deferred, secondary)
    If session has a slug (from JSONL parsing):
      Find card with matching slug
      If found → INSERT session_links(session.id, card.id, "slug")
      Continue

  Step 4: No match → Create discovered card
    Create new card (source=.discovered, column=.done)
    INSERT session_links(session.id, newCard.id, "discovered")

After all sessions processed:
  For each card:
    Set is_current=1 on the session with latest modifiedTime
    Set is_current=0 on all others
```

### What changes in `BackgroundOrchestrator`

`hookSessionLinked` action still fires on SessionStart with tmux name. But instead of
building a `SessionLink` struct with chaining logic, it:
1. Writes to `session_links` (INSERT or UPDATE)
2. Sets the card's `currentSessionId` for activity lookups
3. If the session was previously on a discovered card, the discovered card loses it
   (UPDATE moves ownership). If the discovered card has no remaining sessions, it
   can be cleaned up.

### Context continuation

The old `previousSessionPaths` chaining is deleted. Context continuation (new sessionId
in same tmux or with same slug) is handled naturally:

1. New session fires SessionStart in same tmux → matched by tmux → linked to same card
2. Old session stays in `session_links` with `is_current=0`
3. Card's history = all sessions in `session_links WHERE link_id = card.id`

No explicit chaining needed. The slug and tmux keys do the work.

---

## Change 3: AssignColumn v2

New mapping uses the full activity spectrum. Activity is looked up by the card's
`currentSessionId` (the `is_current=1` session from `session_links`).

```
Priority 1: Live process
  .activelyWorking           → .inProgress

Priority 2: Live tmux
  hasLiveTmux                → .waiting

Priority 3: User intent
  manualOverrides.column     → keep current
  manuallyArchived           → .done

Priority 4: Activity-driven (any known state)
  .needsAttention            → .waiting
  .idleWaiting               → .waiting
  .ended                     → .waiting
  .stale                     → .waiting

Priority 5: No data (nil — cold start, race)
  nil activityState          → NO CHANGE (return link.column)

Priority 6: Classification (unstarted tasks)
  manual/todoist, no session → .backlog
  default                    → link.column (preserve)
```

Key changes from current:
- Every non-null activity state maps to a column (no default `.done` fallthrough)
- `nil` preserves current column (cold start safety)
- Default is preserve, not `.done`

---

## Change 4: Remove Manual Override Clearing

Delete the override-clearing blocks in `.reconciled` and `.activityChanged` reducer cases.

Manual overrides are only cleared by:
- User dragging the card to a different column
- `launchCard` / `resumeCard` actions

Background processes never touch `manualOverrides.column`.

---

## Change 5: AutoCleanup Scoped to Discovered Cards

AutoCleanup's 24h removal only applies to `source == .discovered` cards.
User-created, hook-linked, and Todoist cards in Done are kept indefinitely.

---

## Data Migration

No migration. Clean slate approach:

1. Before deploy: delete all Done cards from DB (`DELETE FROM links WHERE "column" = 'done'`)
2. Drop `session_paths` table
3. Create `session_links` table (empty)
4. Deploy new binary
5. Reconciler populates `session_links` from disk scan on first run

No compensating code. No special first-run logic. If data causes problems, delete
the data — don't patch the code around it.

---

## Files Changed

| File | Change |
|------|--------|
| `CoordinationStore.swift` | New `session_links` table, drop `session_paths`, remove `override_tmux` |
| `Link.swift` | Remove `SessionLink` struct, remove `sessionLink` property. No new fields — current session queried from `session_links` |
| `CardReconciler.swift` | Association hierarchy (tmux → slug → discovered), write to `session_links` |
| `BackgroundOrchestrator.swift` | `hookSessionLinked` writes to `session_links` instead of building SessionLink |
| `BoardStore.swift` | Remove context continuation logic, remove override clearing, use `currentSessionId` for activity |
| `AssignColumn.swift` | Activity spectrum mapping, `nil` → preserve, no default `.done` |
| `AutoCleanup.swift` | Scope 24h removal to `source == .discovered` |
| `UpdateCardColumn.swift` | No change (still wraps AssignColumn) |

## Files Deleted / Removed

| Item | Reason |
|------|--------|
| `SessionLink` struct in `Link.swift` | Replaced by `session_links` table + slug on card |
| `previousSessionPaths` field | Natural association via slug replaces explicit chaining |
| `ManualOverrides.tmuxSession` | Never used meaningfully |
| Override-clearing logic in `BoardStore.swift` | User intent is sacred |

## Unchanged

| Item | Why |
|------|-----|
| `TmuxLink` struct | Still tracks terminal sessions (primary + extras) |
| `tmux_sessions` table | Terminal management unchanged |
| `queued_prompts` table | Prompt queue unchanged |
| `isLaunching` lock | Still needed during launch window |
| `preservedIds` in `.reconciled` | Still needed for race protection |
| `ClaudeCodeActivityDetector` | Activity detection logic unchanged |
| `ClaudeCodeSessionDiscovery` | Session file scanning unchanged |
