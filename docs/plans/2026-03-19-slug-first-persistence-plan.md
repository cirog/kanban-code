# Slug-First Persistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the JSON blob persistence with a fully normalized relational schema where SQLite enforces slug uniqueness, eliminating duplicate cards by construction.

**Architecture:** Four tables (links, session_paths, tmux_sessions, queued_prompts) replace the single `links(id, session_id, data BLOB)` table. `SessionLink` and `TmuxLink` structs remain as in-memory views hydrated from DB rows — all consumers continue using `link.sessionLink?.sessionId` etc. unchanged. Migration runs automatically on first launch.

**Data Access Layer:** All SQLite operations are encapsulated in `CoordinationStore` (the existing actor). No raw SQL exists outside this file. The store exposes domain-level methods — consumers never see SQL, table names, or column names. The public API speaks only in domain types (`Link`, `SessionLink`, etc.).

**Tech Stack:** Swift, SQLite3 (direct C API — no ORM), Swift Testing framework

**Design doc:** `docs/plans/2026-03-19-slug-first-persistence-design.md`

---

## Task 0: Define CoordinationStore Public API (Data Access Layer)

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`

Before touching the schema, define the complete public API that all consumers will use. No SQL leaks outside this class.

**Step 1: Design the public interface**

The store already acts as the data access layer. Expand its API to cover all operations the codebase needs:

```swift
public actor CoordinationStore {
    // --- Card CRUD ---
    public func readLinks() throws -> [Link]
    public func upsertLink(_ link: Link) throws
    public func removeLink(id: String) throws

    // --- Lookup ---
    public func linkById(_ id: String) throws -> Link?
    public func linkForSession(_ sessionId: String) throws -> Link?
    public func findBySlug(_ slug: String) throws -> Link?

    // --- Session chaining ---
    public func addSessionPath(linkId: String, sessionId: String, path: String?) throws

    // --- Bulk operations ---
    public func writeLinks(_ links: [Link]) throws
    public func modifyLinks(_ transform: (inout [Link]) -> Void) throws

    // --- Mutation helpers ---
    public func updateLink(id: String, update: (inout Link) -> Void) throws
    public func updateLink(sessionId: String, update: (inout Link) -> Void) throws
    public func removeOrphans() throws
}
```

**Step 2: Verify no raw SQL exists outside CoordinationStore**

Search the codebase for any direct sqlite3 calls or SQL strings outside of `CoordinationStore.swift`. There should be none. If any exist, they must be moved into CoordinationStore methods.

**Step 3: Commit**

```bash
git commit -m "docs: define CoordinationStore data access layer API"
```

---

## Task 1: New Schema Creation + Migration

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`
- Test: `Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift`

This is the foundation. Create the new tables alongside the old one, migrate data, drop the old table.

**Step 1: Write failing test for new schema**

Add a test that creates a CoordinationStore, inserts a Link with session paths via the new API, reads it back, and verifies all fields round-trip. This test will fail because the new tables and methods don't exist yet.

```swift
@Test("Relational schema: link with session paths round-trips")
func relationalRoundTrip() async throws {
    let store = CoordinationStore(basePath: tmpDir)
    var link = Link(id: "card-1", name: "Test Card", projectPath: "/test", column: .inProgress)
    link.sessionLink = SessionLink(sessionId: "session-1", sessionPath: "/path/to/s1.jsonl", slug: "test-slug")
    try await store.upsertLink(link)

    let loaded = try await store.readLinks()
    #expect(loaded.count == 1)
    #expect(loaded[0].id == "card-1")
    #expect(loaded[0].name == "Test Card")
    #expect(loaded[0].sessionLink?.sessionId == "session-1")
    #expect(loaded[0].sessionLink?.sessionPath == "/path/to/s1.jsonl")
    #expect(loaded[0].sessionLink?.slug == "test-slug")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter CoordinationStoreTests`
Expected: Test fails (new schema doesn't produce correct results yet)

**Step 3: Implement new schema creation**

In `CoordinationStore.createTable()`, add the new tables (links_v2, session_paths, tmux_sessions, queued_prompts) with proper constraints. Enable `PRAGMA foreign_keys = ON` in `openDatabase()`.

Create new `createTablesV2()` method with the full DDL from the design doc. Quote `"column"` as it's a reserved word.

**Step 4: Implement relational upsertLink**

Rewrite `upsertLink(_:)` to:
1. INSERT OR REPLACE into `links` with all scalar columns extracted from the Link struct
2. DELETE + re-INSERT into `session_paths` for the link's sessions (current + previous)
3. DELETE + re-INSERT into `tmux_sessions` for TmuxLink data
4. DELETE + re-INSERT into `queued_prompts` for QueuedPrompt data
All wrapped in a transaction.

**Step 5: Implement relational readLinks**

Rewrite `readLinks()` to:
1. SELECT all rows from `links`
2. For each link, SELECT from `session_paths`, `tmux_sessions`, `queued_prompts`
3. Assemble the `SessionLink` struct from session_paths rows (is_current=1 → sessionId/sessionPath, others → previousSessionPaths)
4. Assemble `TmuxLink` from tmux_sessions rows
5. Assemble `[QueuedPrompt]` from queued_prompts rows
6. Return assembled Link structs

**Step 6: Implement migration from old schema**

In `createTablesV2()`, check if old `links` table exists (has `data` column). If so:
1. Read all rows from old table using the existing JSON decode path
2. Merge any duplicate slugs (one-time cleanup)
3. Insert into new tables
4. Drop old table

**Step 7: Run test to verify it passes**

Run: `swift test --filter CoordinationStoreTests`
Expected: All tests pass

**Step 8: Commit**

```bash
git add Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift
git commit -m "feat: relational schema for CoordinationStore with migration"
```

---

## Task 2: Slug Uniqueness Enforcement

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`
- Test: `Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift`

**Step 1: Write failing test**

```swift
@Test("UNIQUE slug constraint prevents duplicate cards")
func slugUniqueness() async throws {
    let store = CoordinationStore(basePath: tmpDir)
    var card1 = Link(id: "card-1", column: .done)
    card1.sessionLink = SessionLink(sessionId: "s1", sessionPath: "/s1.jsonl", slug: "same-slug")
    var card2 = Link(id: "card-2", column: .done)
    card2.sessionLink = SessionLink(sessionId: "s2", sessionPath: "/s2.jsonl", slug: "same-slug")

    try await store.upsertLink(card1)
    // Second insert with same slug should fail or merge
    do {
        try await store.upsertLink(card2)
        Issue.record("Expected slug conflict")
    } catch {
        // Expected: UNIQUE constraint violation
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter slugUniqueness`
Expected: FAIL — currently no UNIQUE constraint on slug

**Step 3: Verify UNIQUE constraint is enforced**

The schema from Task 1 already has `slug TEXT UNIQUE` on the links table. Verify the upsertLink method does NOT use `INSERT OR REPLACE` keyed on slug (it should key on `id`), so a second card with the same slug hits the constraint.

**Step 4: Run test to verify it passes**

Run: `swift test --filter CoordinationStoreTests`
Expected: All pass

**Step 5: Commit**

```bash
git commit -m "test: verify UNIQUE slug constraint prevents duplicate cards"
```

---

## Task 3: Update findBySlug and findBySessionId queries

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`
- Test: `Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift`

**Step 1: Write failing tests**

```swift
@Test("findBySlug returns correct card")
func findBySlug() async throws {
    let store = CoordinationStore(basePath: tmpDir)
    var link = Link(id: "card-1", column: .done)
    link.sessionLink = SessionLink(sessionId: "s1", slug: "my-slug")
    try await store.upsertLink(link)

    let found = try await store.findBySlug("my-slug")
    #expect(found?.id == "card-1")

    let notFound = try await store.findBySlug("nonexistent")
    #expect(notFound == nil)
}

@Test("findBySessionId searches session_paths table")
func findBySessionId() async throws {
    let store = CoordinationStore(basePath: tmpDir)
    var link = Link(id: "card-1", column: .done)
    link.sessionLink = SessionLink(
        sessionId: "s2",
        sessionPath: "/s2.jsonl",
        slug: "my-slug",
        previousSessionPaths: ["/s1.jsonl"]
    )
    try await store.upsertLink(link)

    // Should find by current session
    let found1 = try await store.linkForSession("s2")
    #expect(found1?.id == "card-1")
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Implement findBySlug**

```swift
public func findBySlug(_ slug: String) throws -> Link? {
    // SELECT from links WHERE slug = ?, then hydrate with child tables
}
```

**Step 4: Update linkForSession to use session_paths table**

The existing `linkForSession(_:)` queries `session_id` column on the old table. Update to JOIN `session_paths`:

```sql
SELECT l.id FROM links l
JOIN session_paths sp ON sp.link_id = l.id
WHERE sp.session_id = ?
```

**Step 5: Run tests, verify pass**

**Step 6: Commit**

```bash
git commit -m "feat: add findBySlug and update findBySessionId for relational schema"
```

---

## Task 4: Add addSessionPath method

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`
- Test: `Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift`

This is the key method the reconciler will use instead of mergeDuplicateSlugs. When a new session with an existing slug is discovered, it adds a row to session_paths and marks it current.

**Step 1: Write failing test**

```swift
@Test("addSessionPath chains sessions and marks new as current")
func addSessionPath() async throws {
    let store = CoordinationStore(basePath: tmpDir)
    var link = Link(id: "card-1", column: .done)
    link.sessionLink = SessionLink(sessionId: "s1", sessionPath: "/s1.jsonl", slug: "my-slug")
    try await store.upsertLink(link)

    // Chain a new session
    try await store.addSessionPath(linkId: "card-1", sessionId: "s2", path: "/s2.jsonl")

    let loaded = try await store.readLinks()
    #expect(loaded.count == 1)
    let card = loaded[0]
    // New session is current
    #expect(card.sessionLink?.sessionId == "s2")
    #expect(card.sessionLink?.sessionPath == "/s2.jsonl")
    // Old session is in previousSessionPaths
    #expect(card.sessionLink?.previousSessionPaths == ["/s1.jsonl"])
}
```

**Step 2: Run test to verify it fails**

**Step 3: Implement addSessionPath**

```swift
public func addSessionPath(linkId: String, sessionId: String, path: String?) throws {
    ensureInitialized()
    // 1. Mark all existing paths for this link as not current
    exec("UPDATE session_paths SET is_current = 0 WHERE link_id = '\(linkId)'")
    // 2. Insert new path as current
    // Use parameterized query for safety
    let sql = "INSERT OR REPLACE INTO session_paths (link_id, session_id, path, is_current, created_at) VALUES (?, ?, ?, 1, ?)"
    // ... bind and execute
}
```

**Step 4: Run tests, verify pass**

**Step 5: Commit**

```bash
git commit -m "feat: addSessionPath method for session chaining"
```

---

## Task 5: Remove mergeDuplicateSlugs from CardReconciler

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/CardReconciler.swift`
- Modify: `Tests/ClaudeBoardCoreTests/CardReconcilerTests.swift`

**Step 1: Update ReconcileResult to drop mergedAwayCardIds**

Remove the `mergedAwayCardIds` field from `ReconcileResult`. Update all call sites.

**Step 2: Remove mergeDuplicateSlugs method**

Delete the entire `mergeDuplicateSlugs` private method and its call at line 148.

**Step 3: Update reconciler tests**

- `slugMergesDuplicateCards`: This test verified post-hoc merge. **Delete it** — the DB constraint now prevents this scenario.
- `slugMergePreservesCustomizations`: **Delete** — same reason.
- `slugMergeSkipsArchived`: **Delete** — same reason.
- `noDuplicatePaths`: **Update** — still valid but no longer tests merge behavior; update to verify session chaining via the reconciler loop.
- Keep: `slugMatchChainsSession`, `noSlugCreatesNewCard`, `multipleChains`, `sessionIdPriorityOverSlug` — these test the session loop, not the merge.

**Step 4: Run all tests**

Run: `swift test`
Expected: All pass

**Step 5: Commit**

```bash
git commit -m "refactor: remove mergeDuplicateSlugs — UNIQUE constraint prevents duplicates"
```

---

## Task 6: Simplify Reducer (.reconciled case)

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`
- Modify: `Tests/ClaudeBoardCoreTests/ReducerTests.swift`

**Step 1: Remove mergedAwayCardIds handling**

In the `.reconciled` case (line ~823):
- Remove the `mergedAwayCardIds` removal block (lines 836-842)
- Remove the `propagateSessionMetadata` helper method and its calls (lines 887-895)
- Remove `mergedAwayCardIds` from `ReconciliationResult` struct

**Step 2: Update the reconcile() method**

In `BoardStore.reconcile()` (line ~1332):
- Remove `mergedAwayCardIds` from the `ReconciliationResult` construction

**Step 3: Update reducer tests**

Any tests that verify mergedAwayCardIds behavior should be updated or removed.

**Step 4: Run all tests**

Run: `swift test`
Expected: All pass

**Step 5: Commit**

```bash
git commit -m "refactor: simplify reducer — remove mergedAwayCardIds and propagateSessionMetadata"
```

---

## Task 7: Update Link struct — remove Codable persistence dependency

**Files:**
- Modify: `Sources/ClaudeBoardCore/Domain/Entities/Link.swift`
- Test: `Tests/ClaudeBoardCoreTests/EntityTests.swift`

**Step 1: Keep SessionLink struct but mark Codable as legacy**

`SessionLink` stays as a struct — it's the in-memory representation hydrated from DB rows. Keep `Codable` conformance for backward-compat migration (reading old JSON blobs), but it's no longer used for persistence writes.

**Step 2: Remove the backward-compatible Codable init/encode**

The custom `init(from decoder:)` that reads legacy flat `sessionId`/`sessionPath` keys can be kept for migration but should be documented as legacy-only.

**Step 3: Run all tests**

Run: `swift test`
Expected: All pass

**Step 4: Commit**

```bash
git commit -m "refactor: document SessionLink Codable as migration-only"
```

---

## Task 8: Update EffectHandler and BackgroundOrchestrator

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/EffectHandler.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift`

These files access `sessionLink?.sessionPath` and `sessionLink?.sessionId` directly. Since `SessionLink` remains as a computed struct on `Link`, **these files should work without changes** after Task 1. Verify by running tests.

**Step 1: Run full test suite**

Run: `swift test`
Expected: All pass. If any fail, fix the specific accessor paths.

**Step 2: Commit (if any changes needed)**

```bash
git commit -m "fix: update EffectHandler/BackgroundOrchestrator for relational schema"
```

---

## Task 9: Update CardDetailView — allSessionPaths from DB

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`

The `allSessionPaths` computed property (added in the earlier fix) reads from `card.link.sessionLink?.previousSessionPaths`. Since `SessionLink` is now hydrated from `session_paths` rows, this should work automatically. Verify by building.

**Step 1: Build**

Run: `swift build`
Expected: Clean build

**Step 2: Deploy and manually verify**

Run: `make deploy`
Open a card with chained sessions. Verify:
- History tab shows all sessions
- Prompt tab shows prompts from all sessions
- No duplicate cards on the board

**Step 3: Commit (if any changes needed)**

```bash
git commit -m "fix: verify CardDetailView works with relational session_paths"
```

---

## Task 10: Clean up old CoordinationStore tests

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift`

**Step 1: Update existing tests**

Update all existing CoordinationStore tests to work with the new relational schema. Tests that verify JSON blob round-tripping should be rewritten to verify column-level persistence.

**Step 2: Add migration test**

Write a test that creates an old-format database (with `data BLOB` column), inserts a few legacy JSON rows, then opens a new CoordinationStore against it and verifies migration produced correct relational data.

**Step 3: Run all tests**

Run: `swift test`
Expected: All 383+ tests pass

**Step 4: Commit**

```bash
git commit -m "test: update CoordinationStore tests for relational schema"
```

---

## Task 11: Final integration test + deploy

**Files:**
- Test: `Tests/ClaudeBoardCoreTests/TranscriptConcatenationTests.swift`

**Step 1: Run full test suite**

Run: `swift test`
Expected: All pass

**Step 2: Deploy**

Run: `make deploy`

**Step 3: Manual verification**

1. ClaudeBoard launches, cards appear (migration ran successfully)
2. No duplicate cards for slug-chained sessions
3. History/Prompt tabs show all sessions for chained cards
4. Creating new sessions, resuming sessions — all work
5. Delete a card — cascade removes session_paths, tmux_sessions, queued_prompts

**Step 4: Final commit**

```bash
git commit -m "chore: final integration verification for slug-first persistence"
```

---

## Execution Notes

- **Migration safety:** The migration runs in a transaction. If it fails, the old schema is untouched. The app will retry next launch.
- **Foreign keys:** `PRAGMA foreign_keys = ON` must be set after every `sqlite3_open` call. SQLite does not persist this pragma.
- **Backward compat:** The `Link` struct keeps its Codable conformance for one purpose only: decoding old JSON blobs during migration. After migration, Codable is not used for persistence.
- **Risk area:** The `writeLinks()` bulk-write method (used by the reducer's persist effect) needs to handle the multi-table writes transactionally. This is the most complex single change.
