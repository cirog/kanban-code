# Session & Column Redesign — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Re-architect session-to-card association and column assignment based on the theoretical Claude Code session data model, fixing 5 observed problems.

**Architecture:** Replace `session_paths` (M:N) with `session_links` (N:1 via PK on session_id). Delete `SessionLink` struct — cards use `slug` field for association, current session queried from DB. Rewrite `AssignColumn` to use full activity spectrum with nil=preserve. Remove manual override clearing. Scope AutoCleanup to discovered cards only.

**Tech Stack:** Swift 6.2, SQLite, Swift Testing framework

**Reference:** `docs/plans/2026-03-21-column-assignment-redesign-design.md`, `docs/reference/claude-session-data-model.md`

---

### Task 1: AssignColumn v2 — Tests

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/SimplifiedAssignColumnTests.swift`

**Step 1: Rewrite the test file**

Replace the "Removed behaviors" section (lines 111-149) and update existing tests. The new tests validate:
- Activity states `.needsAttention`, `.idleWaiting`, `.ended`, `.stale` → `.waiting` (not `.done`)
- `nil` activity with no tmux → preserves current column (cold start safety)
- Discovered cards with `nil` activity keep their column
- Existing priority 1 and 2 tests stay the same

The test for `noProcess_default_goesToDone` (line 105-109) changes: `nil` activity now preserves the column. Since `Link(source: .discovered)` defaults to `.done`, the result stays `.done` — but the reason changes (preserve, not default).

Replace lines 91 onwards (the "Priority 3: Classification" section and "Removed behaviors" section) with:

```swift
    // MARK: - Priority 3: No Live Process — Classification

    @Test func noProcess_manualTask_noSession_goesToBacklog() {
        let link = Link(source: .manual)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .backlog)
    }

    @Test func noProcess_todoistTask_noSession_goesToBacklog() {
        let link = Link(source: .todoist)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .backlog)
    }

    // MARK: - Priority 4: Activity-Driven (any known state → waiting)

    @Test func noProcess_needsAttention_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .needsAttention, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func noProcess_idleWaiting_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .idleWaiting, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func noProcess_ended_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .ended, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func noProcess_stale_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .stale, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    // MARK: - Priority 5: No Data (nil) — Preserve Column

    @Test func nilActivity_noTmux_preservesWaiting() {
        let link = Link(column: .waiting, source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func nilActivity_noTmux_preservesInProgress() {
        let link = Link(column: .inProgress, source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .inProgress)
    }

    @Test func nilActivity_noTmux_preservesDone() {
        let link = Link(column: .done, source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func nilActivity_noTmux_preservesBacklog() {
        let link = Link(column: .backlog, source: .manual)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .backlog)
    }
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter SimplifiedAssignColumnTests 2>&1`

Expected: Multiple FAILs (activity states expect `.waiting` but get `.done`, nil-preserve tests expect current column but get `.done`)

**Step 3: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/SimplifiedAssignColumnTests.swift
git commit -m "test: AssignColumn v2 — activity spectrum and nil-preserve tests"
```

---

### Task 2: AssignColumn v2 — Implementation

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/AssignColumn.swift`

**Step 1: Rewrite AssignColumn.assign()**

Replace the entire file with:

```swift
import Foundation

/// Determines which Kanban column a link should be in based on its state.
///
/// Priority layers:
///   1. Active work (.activelyWorking) → inProgress
///   2. Live tmux → waiting
///   3. User intent (manual override, archived)
///   4. Activity-driven (any known state → waiting)
///   5. No data (nil) → preserve current column
///   6. Classification (unstarted tasks → backlog)
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil,
        hasLiveTmux: Bool = false
    ) -> ClaudeBoardColumn {
        // --- Priority 1: Active work always inProgress ---
        if activityState == .activelyWorking {
            return .inProgress
        }

        // --- Priority 2: Live tmux → waiting ---
        if hasLiveTmux {
            return .waiting
        }

        // --- Priority 3: User intent ---
        if link.manualOverrides.column {
            return link.column
        }

        if link.manuallyArchived {
            return .done
        }

        // --- Priority 4: Activity-driven (any known state → waiting) ---
        if let activity = activityState {
            switch activity {
            case .activelyWorking:
                return .inProgress // Already handled, exhaustive
            case .needsAttention, .idleWaiting, .ended, .stale:
                return .waiting
            }
        }

        // --- Priority 5: No data (nil) — preserve current column ---
        // On cold start or race conditions, we have no activity data.
        // Don't move cards we can't reason about.

        // Exception: unstarted tasks stay in backlog
        if (link.source == .manual || link.source == .todoist) && link.sessionLink == nil {
            return .backlog
        }

        return link.column
    }
}
```

Note: The `link.sessionLink == nil` check on the backlog line will be updated in Task 6 when we remove `SessionLink`. For now it still compiles.

**Step 2: Run tests**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter SimplifiedAssignColumnTests 2>&1`

Expected: ALL PASS

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/AssignColumn.swift
git commit -m "feat: AssignColumn v2 — activity spectrum mapping, nil preserves column"
```

---

### Task 3: AutoCleanup — Tests + Implementation

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/AutoCleanupTests.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/AutoCleanup.swift`

**Step 1: Update test — `removesOldDoneCards` becomes source-aware**

Replace the `removesOldDoneCards` test with:

```swift
    @Test func removesOldDoneCards_discoveredOnly() {
        let oldDiscovered = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600),
            source: .discovered
        )
        let oldManual = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600),
            source: .manual
        )
        let oldHook = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600),
            source: .hook
        )
        let recentDiscovered = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-12 * 3600),
            source: .discovered
        )

        let result = AutoCleanup.clean(links: [oldDiscovered, oldManual, oldHook, recentDiscovered])

        #expect(result.count == 3) // only oldDiscovered removed
        #expect(!result.contains(where: { $0.id == oldDiscovered.id }))
        #expect(result.contains(where: { $0.id == oldManual.id }))
        #expect(result.contains(where: { $0.id == oldHook.id }))
        #expect(result.contains(where: { $0.id == recentDiscovered.id }))
    }
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter AutoCleanupTests 2>&1`

Expected: FAIL — `removesOldDoneCards_discoveredOnly` expects 3 but gets 2 (both old cards removed)

**Step 3: Add source filter to AutoCleanup**

In `AutoCleanup.swift`, change line 28 from:
```swift
            if link.column == .done && link.updatedAt < cutoff {
```
to:
```swift
            if link.column == .done && link.source == .discovered && link.updatedAt < cutoff {
```

**Step 4: Run tests**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter AutoCleanupTests 2>&1`

Expected: ALL PASS

**Step 5: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/AutoCleanupTests.swift Sources/ClaudeBoardCore/UseCases/AutoCleanup.swift
git commit -m "fix: AutoCleanup only expires discovered cards after 24h"
```

---

### Task 4: Remove Manual Override Clearing

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`

**Step 1: Delete override-clearing in `.reconciled` case**

Delete lines 885-894 (the block starting with `// Clear manual column override`):

```swift
                // Clear manual column override when we have definitive data.
                // Backlog is sticky — the user explicitly parked this card.
                if link.manualOverrides.column && link.column != .backlog {
                    if activity != nil && activity != .stale {
                        link.manualOverrides.column = false
                    } else if link.tmuxLink != nil && !hasLiveTmux {
                        link.tmuxLink = nil
                        link.manualOverrides.column = false
                    }
                }
```

**Step 2: Delete override-clearing in `.activityChanged` case**

Delete lines 932-934:

```swift
                // Clear manual backlog override when activity promotes the card
                if activity == .activelyWorking && link.manualOverrides.column && link.column == .backlog {
                    link.manualOverrides.column = false
                }
```

**Step 3: Run full test suite**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1`

Expected: ALL PASS

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "fix: remove manual override clearing — user column pins are sacred"
```

---

### Task 5: Schema Migration — `session_links` Table

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`

**Step 1: Add migration in `migrateSchema()`**

After the existing migration check, add a migration from `session_paths` to `session_links`. Replace the `migrateSchema()` method:

```swift
    private func migrateSchema() {
        let hasSessionPaths = queryInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_paths'") ?? 0
        let hasSessionLinks = queryInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_links'") ?? 0

        if hasSessionPaths == 0 && hasSessionLinks == 0 {
            // Fresh install — create new schema
            exec("DROP TABLE IF EXISTS links")
            createRelationalSchema()
        } else if hasSessionPaths > 0 && hasSessionLinks == 0 {
            // Migration: drop old session_paths, create session_links
            exec("DROP TABLE IF EXISTS session_paths")
            exec("DROP INDEX IF EXISTS idx_sp_session")
            exec("DROP INDEX IF EXISTS idx_sp_current")
            createSessionLinksTable()
        }
    }
```

**Step 2: Update `createRelationalSchema()` — replace `session_paths` with `session_links`**

Replace the `session_paths` CREATE TABLE block (lines 104-115) with `session_links`:

```swift
        createSessionLinksTable()
```

And add a new method:

```swift
    private func createSessionLinksTable() {
        exec("""
            CREATE TABLE IF NOT EXISTS session_links (
                session_id    TEXT PRIMARY KEY,
                link_id       TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
                matched_by    TEXT NOT NULL,
                is_current    INTEGER NOT NULL DEFAULT 0,
                path          TEXT,
                created_at    TEXT NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sl_link ON session_links(link_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_sl_current ON session_links(link_id, is_current) WHERE is_current = 1")
    }
```

**Step 3: Add new session_links CRUD methods**

Add these methods to the public API section:

```swift
    /// Link a session to a card. If the session already exists, UPDATE to new card.
    public func linkSession(sessionId: String, linkId: String, matchedBy: String, path: String?) throws {
        ensureInitialized()
        let sql = """
            INSERT INTO session_links (session_id, link_id, matched_by, is_current, path, created_at)
            VALUES (?, ?, ?, 0, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET link_id = ?, matched_by = ?, path = COALESCE(?, path)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        let now = dateToText(.now)
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (linkId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (matchedBy as NSString).utf8String, -1, nil)
        if let path { sqlite3_bind_text(stmt, 4, (path as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt, 5, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (linkId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (matchedBy as NSString).utf8String, -1, nil)
        if let path { sqlite3_bind_text(stmt, 8, (path as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 8) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoordinationStoreError.stepError(lastError) }
    }

    /// Get the current session ID for a card.
    public func currentSessionId(forLink linkId: String) throws -> String? {
        ensureInitialized()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT session_id FROM session_links WHERE link_id = ? AND is_current = 1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Get the card ID that owns a session.
    public func cardIdForSession(_ sessionId: String) throws -> String? {
        ensureInitialized()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT link_id FROM session_links WHERE session_id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Mark the latest session as current for a card, clearing others.
    public func setCurrentSession(sessionId: String, forLink linkId: String) throws {
        ensureInitialized()
        exec("BEGIN TRANSACTION")
        execParam("UPDATE session_links SET is_current = 0 WHERE link_id = ?", bindings: [linkId])
        execParam("UPDATE session_links SET is_current = 1 WHERE session_id = ? AND link_id = ?", bindings: [sessionId, linkId])
        exec("COMMIT")
    }

    /// Get all session IDs linked to a card.
    public func sessionIds(forLink linkId: String) throws -> [String] {
        ensureInitialized()
        var result: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT session_id FROM session_links WHERE link_id = ? ORDER BY created_at", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return result
    }
```

**Step 4: Update old methods that reference `session_paths`**

- `writeLinks()` line 175: change `exec("DELETE FROM session_paths")` to `exec("DELETE FROM session_links")`
- `upsertLink()` line 209: change `execParam("DELETE FROM session_paths WHERE link_id = ?", ...)` to `execParam("DELETE FROM session_links WHERE link_id = ?", ...)`
- `linkForSession()` lines 231: change `session_paths` to `session_links`
- `removeOrphans()` line 320-321: change `link.sessionLink?.sessionPath` — this will be fully updated in Task 6
- `insertRelational()` lines 390-403: replace the session_paths insertion block with session_links insertion. For now, keep it compatible:

```swift
        // Insert session link (current session only — no previous paths)
        if let sl = link.sessionLink {
            try linkSessionInternal(sessionId: sl.sessionId, linkId: link.id,
                                     matchedBy: "discovered", path: sl.sessionPath)
        }
```

And add the internal helper:
```swift
    private func linkSessionInternal(sessionId: String, linkId: String, matchedBy: String, path: String?) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO session_links (session_id, link_id, matched_by, is_current, path, created_at) VALUES (?, ?, ?, 1, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (linkId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (matchedBy as NSString).utf8String, -1, nil)
        if let path { sqlite3_bind_text(stmt, 4, (path as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt, 5, (dateToText(.now) as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoordinationStoreError.stepError(lastError) }
    }
```

- Delete `insertSessionPath()` method (lines 427-440) — replaced by `linkSessionInternal`
- Delete `hydrateSessionLink()` method (lines 525-564) — no longer needed, session data comes from `session_links` table
- In `readLinks()` line 161: remove `link.sessionLink = try hydrateSessionLink(linkId: link.id)` — will be fully removed in Task 6
- Delete `addSessionPath()` method (lines 258-284) — replaced by `linkSession()`

**Step 5: Build**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1`

Expected: BUILD SUCCEEDED (SessionLink struct still exists, just not hydrated from DB)

**Step 6: Run tests**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1`

Expected: ALL PASS (or known failures in tests that depend on session_paths hydration — these will be fixed in Task 6)

**Step 7: Commit**

```bash
git add Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift
git commit -m "feat: session_links table with PK(session_id) — replaces session_paths"
```

---

### Task 6: Remove SessionLink Struct — The Big Swap

This is the largest task. It touches 12 files and removes 109 references to `sessionLink`.
The key insight: many of these are reads of `link.sessionLink?.sessionId` which need to be
replaced with a lookup from the `session_links` table or the in-memory session index.

**Files:**
- Modify: `Sources/ClaudeBoardCore/Domain/Entities/Link.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/CardReconciler.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/AssignColumn.swift`
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`
- Modify: `Sources/ClaudeBoard/ContentView.swift`
- Modify: `Sources/ClaudeBoard/CardView.swift`
- Modify: `Sources/ClaudeBoard/CardDropIntent.swift`
- Modify: `Sources/ClaudeBoard/ProcessManagerView.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/EffectHandler.swift`
- Modify: various test files

**This task is too large to prescribe line-by-line.** Instead, the implementing agent should:

1. **Delete `SessionLink` struct** from `Link.swift` (lines 6-20)
2. **Remove `sessionLink` property** from `Link` struct, its init parameter, Codable, and backward-compat computed properties (`sessionId`, `sessionPath`, `sessionNumber`)
3. **Remove `ManualOverrides.tmuxSession`** field
4. **Add to `AppState`**: a transient `sessionIdByCardId: [String: String]` dictionary, populated by the reconciler each cycle from `session_links` table
5. **Search-and-replace** every `link.sessionLink?.sessionId` → look up from `state.sessionIdByCardId[link.id]` or from the reconciler's transient index
6. **Update `AssignColumn`** line 42: `link.sessionLink == nil` → check if card has any session in `session_links` (pass a `hasSession: Bool` parameter)
7. **Update `.hookSessionLinked` reducer**: instead of building SessionLink with chaining, dispatch a DB write effect to `linkSession()` and clear `isLaunching`
8. **Update `.reconciled` reducer**: use `state.sessionIdByCardId` for activity lookups
9. **Update `.activityChanged` reducer**: use `state.sessionIdByCardId` for session lookups
10. **Update `CardReconciler`**: remove all `link.sessionLink` references, use the association hierarchy instead
11. **Update views**: replace `link.sessionLink?.sessionId` with the state lookup, `link.sessionLink?.sessionPath` with session path from discovery cache
12. **Fix all compile errors** — there will be many but they're mechanical

**Step 1: Make all changes (guided by compiler errors)**

Run: `swift build 2>&1` after each file to track progress

**Step 2: Run tests**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1`

Fix any test failures. Tests that reference `SessionLink` directly need updating.

**Step 3: Commit**

```bash
git add -A
git commit -m "feat!: remove SessionLink struct — session association via session_links table"
```

---

### Task 7: Reconciler — Association Hierarchy

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/CardReconciler.swift`
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift` (reconcile effect)

**Step 1: Rewrite `CardReconciler.reconcile()`**

The new reconciler:
1. Takes existing `session_links` data as input (already-owned sessions)
2. For each discovered session: check ownership → tmux match → slug match → create discovered card
3. Returns: updated links + new session_link entries to persist

```swift
public enum CardReconciler {

    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let didScanTmux: Bool
        // NEW: existing session ownership from DB
        public let ownedSessionIds: Set<String>

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            didScanTmux: Bool = false,
            ownedSessionIds: Set<String> = []
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.didScanTmux = didScanTmux
            self.ownedSessionIds = ownedSessionIds
        }
    }

    /// A new session-to-card association to persist.
    public struct SessionAssociation: Sendable {
        public let sessionId: String
        public let cardId: String
        public let matchedBy: String  // "tmux" | "slug" | "discovered"
        public let path: String?
    }

    public struct ReconcileResult: Sendable {
        public let links: [Link]
        public let newAssociations: [SessionAssociation]
    }

    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> ReconcileResult {
        var linksById: [String: Link] = [:]
        for link in existing { linksById[link.id] = link }

        // Build slug → cardId index
        var cardIdBySlug: [String: String] = [:]
        for link in existing {
            if let slug = link.slug, !slug.isEmpty {
                cardIdBySlug[slug] = link.id
            }
        }

        var newAssociations: [SessionAssociation] = []

        // A. Process discovered sessions
        for session in snapshot.sessions {
            // Step 1: Already owned?
            if snapshot.ownedSessionIds.contains(session.id) {
                // Update metadata on the owning card (lastActivity, projectPath)
                // We don't know which card owns it here — the caller handles that
                continue
            }

            // Step 2: Slug match
            if let slug = session.slug, !slug.isEmpty,
               let cardId = cardIdBySlug[slug],
               var link = linksById[cardId] {
                // Session matched to existing card via slug
                if !link.manuallyArchived {
                    link.lastActivity = session.modifiedTime
                    if link.projectPath == nil, let pp = session.projectPath {
                        link.projectPath = pp
                    }
                    linksById[cardId] = link
                }
                newAssociations.append(SessionAssociation(
                    sessionId: session.id, cardId: cardId,
                    matchedBy: "slug", path: session.jsonlPath
                ))
                continue
            }

            // Step 3: No match → create discovered card
            ClaudeBoardLog.info("reconciler", "New session \(session.id.prefix(8)) → discovered card")
            let newLink = Link(
                projectPath: session.projectPath,
                slug: session.slug,
                column: .done,
                lastActivity: session.modifiedTime,
                source: .discovered
            )
            linksById[newLink.id] = newLink
            if let slug = session.slug, !slug.isEmpty {
                cardIdBySlug[slug] = newLink.id
            }
            newAssociations.append(SessionAssociation(
                sessionId: session.id, cardId: newLink.id,
                matchedBy: "discovered", path: session.jsonlPath
            ))
        }

        // B. Clear dead tmux links (unchanged)
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))
        let didScanTmux = snapshot.didScanTmux

        for (id, var link) in linksById {
            guard var tmux = link.tmuxLink, didScanTmux else { continue }
            var changed = false
            let primaryAlive = liveTmuxNames.contains(tmux.sessionName)

            if let extras = tmux.extraSessions {
                let liveExtras = extras.filter { liveTmuxNames.contains($0) }
                tmux.extraSessions = liveExtras.isEmpty ? nil : liveExtras
            }

            if !primaryAlive && tmux.extraSessions == nil {
                link.tmuxLink = nil; changed = true
            } else if !primaryAlive {
                tmux.isPrimaryDead = true; link.tmuxLink = tmux; changed = true
            } else {
                if tmux.isPrimaryDead != nil { tmux.isPrimaryDead = nil }
                if tmux != link.tmuxLink { link.tmuxLink = tmux; changed = true }
            }

            if changed { linksById[id] = link }
        }

        return ReconcileResult(
            links: Array(linksById.values),
            newAssociations: newAssociations
        )
    }
}
```

Note: tmux matching happens via hooks (BackgroundOrchestrator), not in the reconciler. The reconciler handles slug matching and discovered card creation.

**Step 2: Update `BoardStore.reconcile()` effect**

Pass `ownedSessionIds` to the snapshot. After reconciliation, persist `newAssociations` via `coordinationStore.linkSession()`. Build the `sessionIdByCardId` transient index.

**Step 3: Update `ReconciliationResult`**

Add `newAssociations: [CardReconciler.SessionAssociation]` to the result struct so the reducer can update state.

**Step 4: Build and test**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 && swift test 2>&1`

Expected: BUILD SUCCEEDED, tests pass

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: reconciler association hierarchy — slug match + discovered cards"
```

---

### Task 8: Clean Slate Migration Script + Deploy

**Step 1: Delete Done cards and old data**

Run before deploying:
```bash
sqlite3 ~/.kanban-code/links.db "DELETE FROM links WHERE [column] = 'done'"
sqlite3 ~/.kanban-code/links.db "SELECT COUNT(*) FROM links"
```

**Step 2: Build and run full test suite**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 && swift test 2>&1`

Expected: BUILD SUCCEEDED, ALL PASS

**Step 3: Deploy**

Run: `cd /Users/ciro/Obsidian/MyVault/Playground/Development/claudeboard && make deploy 2>&1`

**Step 4: Push**

```bash
git push
```
