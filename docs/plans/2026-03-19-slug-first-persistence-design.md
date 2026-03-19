# Slug-First Persistence: Full Relational Schema

## Problem

When Claude Code sessions are continued via `--resume`, a new `.jsonl` file is created with the same slug. The CardReconciler chains these correctly at runtime, but the persistence layer (SQLite) stores each Link as a JSON blob keyed by UUID. Two cards with the same slug can persist as separate rows, causing duplicate cards on the board — especially on startup before reconciliation completes.

The current fix is post-hoc: `mergeDuplicateSlugs()` runs every reconciliation cycle to heal duplicates. This is fragile — it relies on timing and can miss edge cases where slugs aren't yet populated.

## Solution

Replace the single-table JSON blob schema with a fully normalized relational model. Make `slug` a UNIQUE column so SQLite itself prevents duplicates. Move session paths, tmux sessions, and queued prompts to proper child tables with foreign keys and cascade deletes.

## Schema

```sql
-- Core card table (all scalars as columns)
CREATE TABLE links (
  id                TEXT PRIMARY KEY,
  slug              TEXT UNIQUE,
  name              TEXT,
  project_path      TEXT,
  "column"          TEXT NOT NULL DEFAULT 'done',
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  last_activity     TEXT,
  last_opened_at    TEXT,
  source            TEXT NOT NULL DEFAULT 'discovered',
  manually_archived INTEGER NOT NULL DEFAULT 0,
  prompt_body       TEXT,
  prompt_image_paths TEXT,
  todoist_id        TEXT,
  todoist_description TEXT,
  todoist_priority  INTEGER,
  todoist_due       TEXT,
  todoist_labels    TEXT,
  todoist_project_id TEXT,
  notes             TEXT,
  project_id        TEXT,
  assistant         TEXT,
  last_tab          TEXT,
  is_launching      INTEGER,
  sort_order        INTEGER,
  override_tmux     INTEGER NOT NULL DEFAULT 0,
  override_name     INTEGER NOT NULL DEFAULT 0,
  override_column   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE session_paths (
  link_id      TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
  session_id   TEXT NOT NULL,
  path         TEXT,
  is_current   INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL,
  PRIMARY KEY (link_id, session_id)
);
CREATE INDEX idx_sp_session ON session_paths(session_id);
CREATE INDEX idx_sp_current ON session_paths(link_id, is_current) WHERE is_current = 1;

CREATE TABLE tmux_sessions (
  link_id       TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
  session_name  TEXT NOT NULL,
  is_primary    INTEGER NOT NULL DEFAULT 0,
  is_dead       INTEGER NOT NULL DEFAULT 0,
  is_shell_only INTEGER NOT NULL DEFAULT 0,
  tab_name      TEXT,
  PRIMARY KEY (link_id, session_name)
);

CREATE TABLE queued_prompts (
  id           TEXT PRIMARY KEY,
  link_id      TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
  body         TEXT NOT NULL,
  send_auto    INTEGER NOT NULL DEFAULT 1,
  image_paths  TEXT,
  sort_order   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_qp_link ON queued_prompts(link_id);
```

## What this eliminates

| Component | Status |
|-----------|--------|
| `mergeDuplicateSlugs()` in CardReconciler | **Removed** — UNIQUE constraint prevents the condition |
| `mergedAwayCardIds` in ReconcileResult / Reducer | **Removed** — no merge needed |
| `previousSessionPaths` in SessionLink | **Removed** — session_paths table with is_current flag |
| `propagateSessionMetadata()` in Reducer | **Removed** — DB is source of truth |
| JSON blob encode/decode cycle | **Removed** — direct column reads/writes |
| `data BLOB` column | **Removed** — all fields are proper columns |

## Migration

On first launch after upgrade:

1. Read all rows from old `links` table (id, session_id, data BLOB)
2. For each row, decode the JSON blob into the legacy `Link` struct
3. INSERT into new `links` table (all scalar fields mapped to columns)
4. INSERT into `session_paths` (current session + previousSessionPaths)
5. INSERT into `tmux_sessions` (primary + extras from TmuxLink)
6. INSERT into `queued_prompts` (from queuedPrompts array)
7. During migration, if a slug collision is detected, merge the cards (same logic as current mergeDuplicateSlugs but run once)
8. Drop old table, rename new tables

Migration runs inside a transaction — atomic success or rollback.

## Impact on existing code

### Domain layer (`Link.swift`)
- `SessionLink` struct: remove `sessionPath`, `previousSessionPaths`. Keep `sessionId` and `slug` as computed from DB.
- Or: replace `SessionLink` entirely with computed properties that query the store.
- `Link` keeps the same public API but Codable is no longer needed for persistence (only for backward-compat migration).

### Infrastructure (`CoordinationStore.swift`)
- Complete rewrite of read/write methods to use proper SQL
- `readLinks()` → JOIN across all 4 tables, assemble Link structs
- `upsertLink()` → INSERT OR REPLACE into links + child table upserts
- `writeLinks()` → transaction wrapping individual upserts
- New: `addSessionPath(linkId:sessionId:path:)`, `findBySlug(_:)`, `findBySessionId(_:)`

### Reconciler (`CardReconciler.swift`)
- Remove `mergeDuplicateSlugs()` entirely
- Slug match in session loop now uses `findBySlug()` — if found, add session_path row; if not, create new card
- `ReconcileResult` drops `mergedAwayCardIds`

### Reducer (`BoardStore.swift`)
- `.reconciled` case: remove merged-away card removal logic
- Remove `propagateSessionMetadata()` helper
- Simplify the preserve/merge logic since slug uniqueness is guaranteed

### View layer (`CardDetailView.swift`)
- `allSessionPaths` computed property: query session_paths table instead of reading from SessionLink
- `loadPrompts()`, `loadFullHistory()`: use session_paths query for paths

## Design decisions

1. **`prompt_image_paths`, `todoist_labels`, `queued_prompts.image_paths` stay as JSON TEXT** — simple string arrays not worth dedicated tables. SQLite JSON1 functions can query them if needed.

2. **`column` is quoted** in SQL because it's a reserved word. In code, use the backtick or bracket syntax.

3. **`ON DELETE CASCADE`** on all child tables — deleting a card automatically cleans up all related data. Requires `PRAGMA foreign_keys = ON` at connection time.

4. **Partial index on `is_current`** — fast lookup for the active session without scanning all historical paths.

5. **No `session_id` on links table** — the current session is `session_paths WHERE is_current = 1`. Single source of truth.
