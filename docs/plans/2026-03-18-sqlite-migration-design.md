# SQLite Migration for CoordinationStore

## Problem

`links.json` uses read-all/write-all semantics. The reconciler's `persistLinks` (writes all 100+ links) races with individual mutations (`upsertLink` from archive/rename/move), causing user actions to be silently lost.

## Solution

Replace the JSON file backend with SQLite. The `CoordinationStore` actor interface stays identical — callers don't change. Only the internal storage implementation changes from JSON file I/O to SQLite queries.

## Schema

One table, one row per card. Nested objects (SessionLink, TmuxLink, QueuedPrompts, ManualOverrides) stored as JSON blob with indexed columns for queried fields:

```sql
CREATE TABLE links (
    id TEXT PRIMARY KEY,
    session_id TEXT,
    data BLOB NOT NULL,
    UNIQUE(session_id)
);
CREATE INDEX idx_session_id ON links(session_id);
```

- `id` — card KSUID, primary key
- `session_id` — extracted for fast lookup by session (`linkForSession`)
- `data` — full Link encoded as JSON (same encoder/decoder)

No schema migrations needed when Link gains new fields — JSON blob absorbs them.

## Method Mapping

| Method | JSON (before) | SQLite (after) |
|--------|---------------|----------------|
| `writeLinks([Link])` | Overwrite entire file | `DELETE ALL` + batch `INSERT` in transaction |
| `upsertLink(Link)` | Read all → find → update → write all | Single `INSERT OR REPLACE` |
| `readLinks()` | Read + decode entire file | `SELECT data FROM links` → decode each row |
| `removeLink(id:)` | Read all → filter → write all | `DELETE WHERE id = ?` |
| `updateLink(id:, update:)` | Read all → find → mutate → write all | `SELECT` → decode → mutate → `UPDATE` |
| `modifyLinks(_:)` | Read all → transform → write all | `SELECT ALL` → transform → transaction |

## Migration

On `init`, if `links.json` exists and SQLite database doesn't:
1. Read `links.json` with existing decoder
2. Insert all links into SQLite
3. Delete `links.json` (clean cut)
4. Log the migration

If both exist (interrupted migration), SQLite wins.

## SQLite Library

System `sqlite3` via `import SQLite3`. No external dependency, no ORM, no SPM package.

## Files Changed

- **Rewrite**: `CoordinationStore.swift` — swap JSON I/O for SQLite (same public interface)
- **Rewrite**: `CoordinationStoreTests.swift` — same test cases, adapted for SQLite
- **No changes**: `BoardStore.swift`, `EffectHandler.swift`, `Link.swift`, or any caller

## What This Fixes

- Archive/rename/column-move lost across reconciler cycles (row-level update, no overwrite)
- `all_sessions` decode failure wiping all data (one bad row doesn't affect others)
- 368MB log file from repeated corruption recovery cycles
