import Foundation
import SQLite3

/// Data access layer for Link persistence using SQLite.
/// All SQL is encapsulated here — no raw SQL exists outside this file.
/// Relational schema: links + session_links + tmux_sessions + queued_prompts.
public actor CoordinationStore {
    private let dbPath: String
    private let basePath: String
    nonisolated(unsafe) private var db: OpaquePointer?

    private var initialized = false

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.basePath = base
        self.dbPath = (base as NSString).appendingPathComponent("links.db")
    }

    /// Lazy initialization — called from within actor context on first use.
    private func ensureInitialized() {
        guard !initialized else { return }
        initialized = true
        openDatabase()
        migrateSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            ClaudeBoardLog.warn("sqlite", "Failed to open database at \(dbPath)")
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA foreign_keys=ON")
    }

    private func dateToText(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func textToDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    // MARK: - Schema Migration

    /// Ensures the relational schema exists, creating it if needed.
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

        // Migration: remove UNIQUE constraint on slug (no longer an association key)
        migrateSlugDropUnique()
    }

    /// Remove the UNIQUE constraint on slug by rebuilding the links table.
    /// SQLite doesn't support ALTER COLUMN, so we use the rename-recreate pattern.
    private func migrateSlugDropUnique() {
        // Check if the auto-index still exists (indicates UNIQUE constraint)
        let hasUniqueSlug = queryInt("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='sqlite_autoindex_links_2'") ?? 0
        guard hasUniqueSlug > 0 else { return }

        ClaudeBoardLog.info("migration", "Removing UNIQUE constraint from slug column")
        // Disable FK checks during migration to avoid CASCADE issues
        exec("PRAGMA foreign_keys=OFF")
        exec("BEGIN TRANSACTION")
        exec("ALTER TABLE links RENAME TO links_old")
        createLinksTable()
        exec("""
            INSERT INTO links SELECT * FROM links_old
        """)
        exec("DROP TABLE links_old")
        exec("COMMIT")
        exec("PRAGMA foreign_keys=ON")
    }

    private func createLinksTable() {
        exec("""
            CREATE TABLE IF NOT EXISTS links (
                id                TEXT PRIMARY KEY,
                slug              TEXT,
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
            )
        """)
    }

    private func createRelationalSchema() {
        createLinksTable()
        createSessionLinksTable()
        exec("""
            CREATE TABLE IF NOT EXISTS tmux_sessions (
                link_id       TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
                session_name  TEXT NOT NULL,
                is_primary    INTEGER NOT NULL DEFAULT 0,
                is_dead       INTEGER NOT NULL DEFAULT 0,
                is_shell_only INTEGER NOT NULL DEFAULT 0,
                tab_name      TEXT,
                PRIMARY KEY (link_id, session_name)
            )
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS queued_prompts (
                id           TEXT PRIMARY KEY,
                link_id      TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
                body         TEXT NOT NULL,
                send_auto    INTEGER NOT NULL DEFAULT 1,
                image_paths  TEXT,
                sort_order   INTEGER NOT NULL DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_qp_link ON queued_prompts(link_id)")
    }

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

    // MARK: - Public API

    /// Read all links from the database, hydrating child data.
    public func readLinks() throws -> [Link] {
        ensureInitialized()
        var links: [Link] = []
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, slug, name, project_path, "column", created_at, updated_at,
                   last_activity, last_opened_at, source, manually_archived,
                   prompt_body, prompt_image_paths, todoist_id, todoist_description,
                   todoist_priority, todoist_due, todoist_labels, todoist_project_id,
                   notes, project_id, assistant, last_tab, is_launching, sort_order,
                   override_tmux, override_name, override_column
            FROM links
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            var link = hydrateLink(from: stmt)
            link.tmuxLink = try hydrateTmuxLink(linkId: link.id)
            link.queuedPrompts = try hydrateQueuedPrompts(linkId: link.id)
            links.append(link)
        }
        return links
    }

    /// Write all links and their session associations (replaces entire table contents).
    public func writeLinks(_ links: [Link], associations: [CardReconciler.SessionAssociation] = []) throws {
        ensureInitialized()
        exec("BEGIN TRANSACTION")
        exec("DELETE FROM queued_prompts")
        exec("DELETE FROM tmux_sessions")
        exec("DELETE FROM session_links")
        exec("DELETE FROM links")
        do {
            for link in links {
                try insertRelational(link)
            }
            for assoc in associations {
                try insertSessionLink(assoc)
            }
            exec("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    private func insertSessionLink(_ assoc: CardReconciler.SessionAssociation) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO session_links (session_id, link_id, matched_by, is_current, path, created_at) VALUES (?, ?, ?, 0, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (assoc.sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (assoc.cardId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (assoc.matchedBy as NSString).utf8String, -1, nil)
        if let path = assoc.path { sqlite3_bind_text(stmt, 4, (path as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt, 5, (dateToText(.now) as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoordinationStoreError.stepError(lastError) }
    }

    /// Upsert a link: insert or replace by id. Touches only one row + child tables.
    public func upsertLink(_ link: Link) throws {
        ensureInitialized()
        exec("BEGIN TRANSACTION")
        do {
            // Delete existing child rows (if updating)
            // Note: session_links NOT deleted — managed separately via linkSession()
            execParam("DELETE FROM tmux_sessions WHERE link_id = ?", bindings: [link.id])
            execParam("DELETE FROM queued_prompts WHERE link_id = ?", bindings: [link.id])
            try insertRelational(link)
            exec("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    /// Get a single link by its id.
    public func linkById(_ id: String) throws -> Link? {
        ensureInitialized()
        return try queryOneLink("SELECT id, slug, name, project_path, \"column\", created_at, updated_at, last_activity, last_opened_at, source, manually_archived, prompt_body, prompt_image_paths, todoist_id, todoist_description, todoist_priority, todoist_due, todoist_labels, todoist_project_id, notes, project_id, assistant, last_tab, is_launching, sort_order, override_tmux, override_name, override_column FROM links WHERE id = ?", bindings: [id])
    }

    /// Get a single link by session ID (searches session_links table).
    public func linkForSession(_ sessionId: String) throws -> Link? {
        ensureInitialized()
        // Find the link_id from session_links, then load the full link
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT link_id FROM session_links WHERE session_id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let linkId = String(cString: sqlite3_column_text(stmt, 0))
        return try linkById(linkId)
    }

    /// Find a link by its tmux session name.
    public func findByTmuxSessionName(_ name: String) throws -> Link? {
        ensureInitialized()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT link_id FROM tmux_sessions WHERE session_name = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let linkId = String(cString: sqlite3_column_text(stmt, 0))
        return try linkById(linkId)
    }

    /// Find a link by its slug.
    public func findBySlug(_ slug: String) throws -> Link? {
        ensureInitialized()
        return try queryOneLink("SELECT id, slug, name, project_path, \"column\", created_at, updated_at, last_activity, last_opened_at, source, manually_archived, prompt_body, prompt_image_paths, todoist_id, todoist_description, todoist_priority, todoist_due, todoist_labels, todoist_project_id, notes, project_id, assistant, last_tab, is_launching, sort_order, override_tmux, override_name, override_column FROM links WHERE slug = ?", bindings: [slug])
    }

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

    /// Get all session→card mappings (sessionId, linkId, path).
    public func allSessionLinkMappings() throws -> [(sessionId: String, cardId: String, path: String?)] {
        ensureInitialized()
        var result: [(sessionId: String, cardId: String, path: String?)] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT session_id, link_id, path FROM session_links", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let cardId = String(cString: sqlite3_column_text(stmt, 1))
            let path = columnText(stmt, 2)
            result.append((sessionId: sessionId, cardId: cardId, path: path))
        }
        return result
    }

    /// Read all session associations as CardReconciler.SessionAssociation structs.
    public func allSessionAssociations() throws -> [CardReconciler.SessionAssociation] {
        ensureInitialized()
        var result: [CardReconciler.SessionAssociation] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT session_id, link_id, matched_by, path FROM session_links", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let linkId = String(cString: sqlite3_column_text(stmt, 1))
            let matchedBy = String(cString: sqlite3_column_text(stmt, 2))
            let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            result.append(CardReconciler.SessionAssociation(
                sessionId: sessionId, cardId: linkId, matchedBy: matchedBy, path: path
            ))
        }
        return result
    }

    /// Row data for chain segment construction.
    public struct ChainSegmentRow: Sendable {
        public let sessionId: String
        public let cardId: String
        public let matchedBy: String
        public let path: String?
    }

    /// Get session_links rows for a specific card, ordered by created_at DESC (most recent first).
    public func chainSegments(forCardId cardId: String, limit: Int = Int.max) -> [ChainSegmentRow] {
        ensureInitialized()
        var result: [ChainSegmentRow] = []
        var stmt: OpaquePointer?
        let sql = "SELECT session_id, link_id, matched_by, path FROM session_links WHERE link_id = ? ORDER BY created_at DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (cardId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(min(limit, Int(Int32.max))))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let linkId = String(cString: sqlite3_column_text(stmt, 1))
            let matchedBy = String(cString: sqlite3_column_text(stmt, 2))
            let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            result.append(ChainSegmentRow(sessionId: sessionId, cardId: linkId, matchedBy: matchedBy, path: path))
        }
        return result
    }

    /// Count total session_links rows for a card.
    public func chainSegmentCount(forCardId cardId: String) -> Int {
        ensureInitialized()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM session_links WHERE link_id = ?", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (cardId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Update specific fields of a link by link.id.
    public func updateLink(id: String, update: (inout Link) -> Void) throws {
        guard var link = try linkById(id) else { return }
        update(&link)
        link.updatedAt = .now
        try upsertLink(link)
    }

    /// Update specific fields of a link by session ID.
    public func updateLink(sessionId: String, update: (inout Link) -> Void) throws {
        guard var link = try linkForSession(sessionId) else { return }
        update(&link)
        link.updatedAt = .now
        try upsertLink(link)
    }

    /// Remove a link by its id. CASCADE deletes child rows.
    public func removeLink(id: String) throws {
        ensureInitialized()
        execParam("DELETE FROM links WHERE id = ?", bindings: [id])
    }

    /// Remove a link by session ID.
    public func removeLink(sessionId: String) throws {
        ensureInitialized()
        guard let link = try linkForSession(sessionId) else { return }
        try removeLink(id: link.id)
    }

    /// Remove orphaned links whose .jsonl files no longer exist.
    /// Note: With session_links table, orphan cleanup is handled by the reconciler.
    /// This method is a no-op for now.
    public func removeOrphans() throws {
        // No-op: session paths are now in session_links table, not on Link.
        // The reconciler handles cleanup.
    }

    /// Atomic read-modify-write within the actor.
    public func modifyLinks(_ transform: (inout [Link]) -> Void) throws {
        var links = try readLinks()
        transform(&links)
        try writeLinks(links)
    }

    /// The database path for debugging.
    public var path: String { dbPath }

    // MARK: - Private: Insert

    private func insertRelational(_ link: Link) throws {
        let sql = """
            INSERT INTO links (
                id, slug, name, project_path, "column", created_at, updated_at,
                last_activity, last_opened_at, source, manually_archived,
                prompt_body, prompt_image_paths, todoist_id, todoist_description,
                todoist_priority, todoist_due, todoist_labels, todoist_project_id,
                notes, project_id, assistant, last_tab, is_launching, sort_order,
                override_tmux, override_name, override_column
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                slug = excluded.slug, name = excluded.name, project_path = excluded.project_path,
                "column" = excluded."column", updated_at = excluded.updated_at,
                last_activity = excluded.last_activity, last_opened_at = excluded.last_opened_at,
                source = excluded.source, manually_archived = excluded.manually_archived,
                prompt_body = excluded.prompt_body, prompt_image_paths = excluded.prompt_image_paths,
                todoist_id = excluded.todoist_id, todoist_description = excluded.todoist_description,
                todoist_priority = excluded.todoist_priority, todoist_due = excluded.todoist_due,
                todoist_labels = excluded.todoist_labels, todoist_project_id = excluded.todoist_project_id,
                notes = excluded.notes, project_id = excluded.project_id,
                assistant = excluded.assistant, last_tab = excluded.last_tab,
                is_launching = excluded.is_launching, sort_order = excluded.sort_order,
                override_tmux = excluded.override_tmux, override_name = excluded.override_name,
                override_column = excluded.override_column
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        var i: Int32 = 1
        bindText(stmt, &i, link.id)
        bindText(stmt, &i, link.slug)
        bindText(stmt, &i, link.name)
        bindText(stmt, &i, link.projectPath)
        bindText(stmt, &i, link.column.rawValue)
        bindText(stmt, &i, dateToText(link.createdAt))
        bindText(stmt, &i, dateToText(link.updatedAt))
        bindText(stmt, &i, link.lastActivity.map { dateToText($0) })
        bindText(stmt, &i, link.lastOpenedAt.map { dateToText($0) })
        bindText(stmt, &i, link.source.rawValue)
        bindInt(stmt, &i, link.manuallyArchived ? 1 : 0)
        bindText(stmt, &i, link.promptBody)
        bindText(stmt, &i, link.promptImagePaths.map { encodeJsonArray($0) })
        bindText(stmt, &i, link.todoistId)
        bindText(stmt, &i, link.todoistDescription)
        bindOptionalInt(stmt, &i, link.todoistPriority)
        bindText(stmt, &i, link.todoistDue)
        bindText(stmt, &i, link.todoistLabels.map { encodeJsonArray($0) })
        bindText(stmt, &i, link.todoistProjectId)
        bindText(stmt, &i, link.notes)
        bindText(stmt, &i, link.projectId)
        bindText(stmt, &i, link.assistant?.rawValue)
        bindText(stmt, &i, link.lastTab)
        bindOptionalInt(stmt, &i, link.isLaunching == true ? 1 : (link.isLaunching == nil ? nil : 0))
        bindOptionalInt(stmt, &i, link.sortOrder)
        bindInt(stmt, &i, 0) // override_tmux — legacy, always false
        bindInt(stmt, &i, link.manualOverrides.name ? 1 : 0)
        bindInt(stmt, &i, link.manualOverrides.column ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CoordinationStoreError.stepError(lastError)
        }

        // Note: session_links are persisted via writeLinks() associations parameter,
        // not through insertRelational.

        // Insert tmux sessions
        if let tmux = link.tmuxLink {
            try insertTmuxSession(linkId: link.id, name: tmux.sessionName, isPrimary: true,
                                  isDead: tmux.isPrimaryDead == true, isShellOnly: tmux.isShellOnly == true,
                                  tabName: tmux.tabNames?[tmux.sessionName])
            if let extras = tmux.extraSessions {
                for extra in extras {
                    try insertTmuxSession(linkId: link.id, name: extra, isPrimary: false,
                                          isDead: false, isShellOnly: false,
                                          tabName: tmux.tabNames?[extra])
                }
            }
        }

        // Insert queued prompts
        if let prompts = link.queuedPrompts {
            for (idx, prompt) in prompts.enumerated() {
                try insertQueuedPrompt(linkId: link.id, prompt: prompt, sortOrder: idx)
            }
        }
    }

    private func insertTmuxSession(linkId: String, name: String, isPrimary: Bool, isDead: Bool, isShellOnly: Bool, tabName: String?) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO tmux_sessions (link_id, session_name, is_primary, is_dead, is_shell_only, tab_name) VALUES (?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, isPrimary ? 1 : 0)
        sqlite3_bind_int(stmt, 4, isDead ? 1 : 0)
        sqlite3_bind_int(stmt, 5, isShellOnly ? 1 : 0)
        if let tabName { sqlite3_bind_text(stmt, 6, (tabName as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 6) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoordinationStoreError.stepError(lastError) }
    }

    private func insertQueuedPrompt(linkId: String, prompt: QueuedPrompt, sortOrder: Int) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO queued_prompts (id, link_id, body, send_auto, image_paths, sort_order) VALUES (?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (prompt.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (linkId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (prompt.body as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, prompt.sendAutomatically ? 1 : 0)
        if let paths = prompt.imagePaths {
            sqlite3_bind_text(stmt, 5, (encodeJsonArray(paths) as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, Int32(sortOrder))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoordinationStoreError.stepError(lastError) }
    }

    // MARK: - Private: Hydration

    private func hydrateLink(from stmt: OpaquePointer?) -> Link {
        let id = columnText(stmt, 0) ?? ""
        let slug = columnText(stmt, 1)
        let name = columnText(stmt, 2)
        let projectPath = columnText(stmt, 3)
        let column = ClaudeBoardColumn(rawValue: columnText(stmt, 4) ?? "done") ?? .done
        let createdAt = textToDate(columnText(stmt, 5)) ?? .now
        let updatedAt = textToDate(columnText(stmt, 6)) ?? .now
        let lastActivity = textToDate(columnText(stmt, 7))
        let lastOpenedAt = textToDate(columnText(stmt, 8))
        let source = LinkSource(rawValue: columnText(stmt, 9) ?? "discovered") ?? .discovered
        let manuallyArchived = sqlite3_column_int(stmt, 10) != 0
        let promptBody = columnText(stmt, 11)
        let promptImagePaths = columnText(stmt, 12).flatMap { decodeJsonArray($0) }
        let todoistId = columnText(stmt, 13)
        let todoistDescription = columnText(stmt, 14)
        let todoistPriority: Int? = sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 15))
        let todoistDue = columnText(stmt, 16)
        let todoistLabels = columnText(stmt, 17).flatMap { decodeJsonArray($0) }
        let todoistProjectId = columnText(stmt, 18)
        let notes = columnText(stmt, 19)
        let projectId = columnText(stmt, 20)
        let assistant: CodingAssistant? = columnText(stmt, 21).flatMap { CodingAssistant(rawValue: $0) }
        let lastTab = columnText(stmt, 22)
        let isLaunching: Bool? = sqlite3_column_type(stmt, 23) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 23) != 0
        let sortOrder: Int? = sqlite3_column_type(stmt, 24) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 24))
        // column 25 = override_tmux (legacy, ignored)
        let overrideName = sqlite3_column_int(stmt, 26) != 0
        let overrideColumn = sqlite3_column_int(stmt, 27) != 0

        return Link(
            id: id, name: name, projectPath: projectPath, column: column,
            createdAt: createdAt, updatedAt: updatedAt, lastActivity: lastActivity,
            lastOpenedAt: lastOpenedAt,
            manualOverrides: ManualOverrides(name: overrideName, column: overrideColumn),
            manuallyArchived: manuallyArchived, source: source,
            promptBody: promptBody, promptImagePaths: promptImagePaths,
            todoistId: todoistId, todoistDescription: todoistDescription,
            todoistPriority: todoistPriority, todoistDue: todoistDue,
            todoistLabels: todoistLabels, todoistProjectId: todoistProjectId,
            notes: notes, projectId: projectId, slug: slug,
            assistant: assistant, lastTab: lastTab, isLaunching: isLaunching, sortOrder: sortOrder
        )
    }

    private func hydrateTmuxLink(linkId: String) throws -> TmuxLink? {
        var primary: (name: String, isDead: Bool, isShellOnly: Bool)?
        var extras: [String] = []
        var tabNames: [String: String] = [:]

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT session_name, is_primary, is_dead, is_shell_only, tab_name FROM tmux_sessions WHERE link_id = ? ORDER BY is_primary DESC", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let isPrimary = sqlite3_column_int(stmt, 1) != 0
            let isDead = sqlite3_column_int(stmt, 2) != 0
            let isShellOnly = sqlite3_column_int(stmt, 3) != 0
            let tabName = columnText(stmt, 4)

            if isPrimary {
                primary = (name, isDead, isShellOnly)
            } else {
                extras.append(name)
            }
            if let tabName { tabNames[name] = tabName }
        }

        guard let primary else { return nil }

        var tmux = TmuxLink(sessionName: primary.name, extraSessions: extras.isEmpty ? nil : extras,
                            isShellOnly: primary.isShellOnly, isPrimaryDead: primary.isDead)
        if !tabNames.isEmpty { tmux.tabNames = tabNames }
        return tmux
    }

    private func hydrateQueuedPrompts(linkId: String) throws -> [QueuedPrompt]? {
        var prompts: [QueuedPrompt] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, body, send_auto, image_paths FROM queued_prompts WHERE link_id = ? ORDER BY sort_order", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let body = String(cString: sqlite3_column_text(stmt, 1))
            let sendAuto = sqlite3_column_int(stmt, 2) != 0
            let imagePaths = columnText(stmt, 3).flatMap { decodeJsonArray($0) }
            prompts.append(QueuedPrompt(id: id, body: body, sendAutomatically: sendAuto, imagePaths: imagePaths))
        }

        return prompts.isEmpty ? nil : prompts
    }

    private func queryOneLink(_ sql: String, bindings: [String]) throws -> Link? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (idx, val) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), (val as NSString).utf8String, -1, nil)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var link = hydrateLink(from: stmt)
        link.tmuxLink = try hydrateTmuxLink(linkId: link.id)
        link.queuedPrompts = try hydrateQueuedPrompts(linkId: link.id)
        return link
    }

    // MARK: - Private: SQLite Helpers

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, col))
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: inout Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
        idx += 1
    }

    private func bindInt(_ stmt: OpaquePointer?, _ idx: inout Int32, _ value: Int) {
        sqlite3_bind_int(stmt, idx, Int32(value))
        idx += 1
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ idx: inout Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, idx, Int32(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
        idx += 1
    }

    private func encodeJsonArray(_ arr: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func decodeJsonArray(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return arr.isEmpty ? nil : arr
    }

    private func execParam(_ sql: String, bindings: [String]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, val) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (val as NSString).utf8String, -1, nil)
        }
        sqlite3_step(stmt)
    }

    private func queryInt(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }
}

// MARK: - Errors

enum CoordinationStoreError: Error, LocalizedError {
    case prepareError(String)
    case stepError(String)

    var errorDescription: String? {
        switch self {
        case .prepareError(let msg): "SQLite prepare failed: \(msg)"
        case .stepError(let msg): "SQLite step failed: \(msg)"
        }
    }
}

