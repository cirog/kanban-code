import Foundation
import SQLite3

/// Data access layer for Link persistence using SQLite.
/// All SQL is encapsulated here — no raw SQL exists outside this file.
/// Relational schema: links + session_paths + tmux_sessions + queued_prompts.
public actor CoordinationStore {
    private let dbPath: String
    private let basePath: String
    nonisolated(unsafe) private var db: OpaquePointer?

    /// Legacy JSON encoder/decoder — used only for migration from old blob schema.
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var initialized = false

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.basePath = base
        self.dbPath = (base as NSString).appendingPathComponent("links.db")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
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

    /// Detects current schema version and migrates as needed.
    private func migrateSchema() {
        // Check if we have the new relational schema (session_paths table exists)
        let hasRelational = queryInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_paths'") ?? 0

        if hasRelational > 0 {
            // Already on relational schema — check for links.json migration
            migrateFromJson()
            return
        }

        // Check if old blob schema exists
        let hasOldLinks = queryInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='links'") ?? 0

        if hasOldLinks > 0 {
            // Old blob schema exists — migrate to relational
            migrateFromBlobSchema()
        } else {
            // Fresh install — create relational schema directly
            createRelationalSchema()
            migrateFromJson()
        }
    }

    private func createRelationalSchema() {
        exec("""
            CREATE TABLE IF NOT EXISTS links (
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
            )
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS session_paths (
                link_id      TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
                session_id   TEXT NOT NULL,
                path         TEXT,
                is_current   INTEGER NOT NULL DEFAULT 0,
                created_at   TEXT NOT NULL,
                PRIMARY KEY (link_id, session_id)
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sp_session ON session_paths(session_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_sp_current ON session_paths(link_id, is_current) WHERE is_current = 1")
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

    /// Migrate from old blob schema to relational.
    private func migrateFromBlobSchema() {
        // Read all links from old blob schema
        var oldLinks: [Link] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT data FROM links", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let blob = sqlite3_column_blob(stmt, 0) {
                    let size = Int(sqlite3_column_bytes(stmt, 0))
                    let data = Data(bytes: blob, count: size)
                    if let link = try? decoder.decode(Link.self, from: data) {
                        oldLinks.append(link)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)

        if oldLinks.isEmpty {
            // No data to migrate — just recreate
            exec("DROP TABLE IF EXISTS links")
            createRelationalSchema()
            return
        }

        // Merge duplicate slugs before migration
        var bySlug: [String: [Link]] = [:]
        var noSlug: [Link] = []
        for link in oldLinks {
            if let slug = link.sessionLink?.slug, !slug.isEmpty {
                bySlug[slug, default: []].append(link)
            } else {
                noSlug.append(link)
            }
        }
        var mergedLinks: [Link] = noSlug
        for (_, group) in bySlug {
            if group.count == 1 {
                mergedLinks.append(group[0])
            } else {
                // Merge: pick card with manual overrides, then most recent
                let sorted = group.sorted { a, b in
                    let aHas = a.manualOverrides.name || a.manualOverrides.column
                    let bHas = b.manualOverrides.name || b.manualOverrides.column
                    if aHas != bHas { return aHas }
                    return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
                }
                var survivor = sorted[0]
                for loser in sorted.dropFirst() {
                    // Collect previous session paths
                    if let path = loser.sessionLink?.sessionPath {
                        var prev = survivor.sessionLink?.previousSessionPaths ?? []
                        if !prev.contains(path) { prev.append(path) }
                        survivor.sessionLink?.previousSessionPaths = prev
                    }
                    if let loserPrev = loser.sessionLink?.previousSessionPaths {
                        var prev = survivor.sessionLink?.previousSessionPaths ?? []
                        for p in loserPrev where !prev.contains(p) { prev.append(p) }
                        survivor.sessionLink?.previousSessionPaths = prev
                    }
                    if survivor.tmuxLink == nil { survivor.tmuxLink = loser.tmuxLink }
                    if let prompts = loser.queuedPrompts {
                        survivor.queuedPrompts = (survivor.queuedPrompts ?? []) + prompts
                    }
                }
                // Remove survivor's current path from previous
                if let current = survivor.sessionLink?.sessionPath {
                    survivor.sessionLink?.previousSessionPaths?.removeAll { $0 == current }
                }
                if survivor.sessionLink?.previousSessionPaths?.isEmpty == true {
                    survivor.sessionLink?.previousSessionPaths = nil
                }
                mergedLinks.append(survivor)
            }
        }

        // Drop old table, create new schema, insert migrated data
        exec("DROP TABLE IF EXISTS links")
        createRelationalSchema()

        exec("BEGIN TRANSACTION")
        for link in mergedLinks {
            do {
                try insertRelational(link)
            } catch {
                ClaudeBoardLog.warn("sqlite", "Migration insert failed for \(link.id): \(error)")
            }
        }
        exec("COMMIT")
        ClaudeBoardLog.info("sqlite", "Migrated \(oldLinks.count) blob links → \(mergedLinks.count) relational links")
    }

    /// One-time migration: import links.json into SQLite, then delete the JSON file.
    private func migrateFromJson() {
        let jsonPath = (basePath as NSString).appendingPathComponent("links.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: jsonPath) else { return }
        if let count = queryInt("SELECT COUNT(*) FROM links"), count > 0 { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            let container = try decoder.decode(LinksContainer.self, from: data)
            exec("BEGIN TRANSACTION")
            for link in container.links {
                try insertRelational(link)
            }
            exec("COMMIT")
            try fm.removeItem(atPath: jsonPath)
            for suffix in [".bkp", ".tmp"] {
                try? fm.removeItem(atPath: jsonPath + suffix)
            }
            ClaudeBoardLog.info("sqlite", "Migrated \(container.links.count) links from links.json")
        } catch {
            exec("ROLLBACK")
            ClaudeBoardLog.warn("sqlite", "Migration from links.json failed: \(error)")
        }
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
            link.sessionLink = try hydrateSessionLink(linkId: link.id)
            link.tmuxLink = try hydrateTmuxLink(linkId: link.id)
            link.queuedPrompts = try hydrateQueuedPrompts(linkId: link.id)
            links.append(link)
        }
        return links
    }

    /// Write all links (replaces entire table contents).
    public func writeLinks(_ links: [Link]) throws {
        ensureInitialized()
        exec("BEGIN TRANSACTION")
        exec("DELETE FROM queued_prompts")
        exec("DELETE FROM tmux_sessions")
        exec("DELETE FROM session_paths")
        exec("DELETE FROM links")
        do {
            for link in links {
                try insertRelational(link)
            }
            exec("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    /// Upsert a link: insert or replace by id. Touches only one row + child tables.
    /// Throws if slug conflicts with a DIFFERENT card (UNIQUE constraint).
    public func upsertLink(_ link: Link) throws {
        ensureInitialized()
        // Check for slug conflict with a different card BEFORE modifying anything
        if let slug = link.sessionLink?.slug, !slug.isEmpty {
            var checkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM links WHERE slug = ? AND id != ?", -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(checkStmt, 1, (slug as NSString).utf8String, -1, nil)
                sqlite3_bind_text(checkStmt, 2, (link.id as NSString).utf8String, -1, nil)
                let hasConflict = sqlite3_step(checkStmt) == SQLITE_ROW
                sqlite3_finalize(checkStmt)
                if hasConflict {
                    throw CoordinationStoreError.slugConflict(slug)
                }
            }
        }

        exec("BEGIN TRANSACTION")
        do {
            // Delete existing child rows (if updating)
            execParam("DELETE FROM session_paths WHERE link_id = ?", bindings: [link.id])
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

    /// Get a single link by session ID (searches session_paths table).
    public func linkForSession(_ sessionId: String) throws -> Link? {
        ensureInitialized()
        // Find the link_id from session_paths, then load the full link
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT link_id FROM session_paths WHERE session_id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let linkId = String(cString: sqlite3_column_text(stmt, 0))
        return try linkById(linkId)
    }

    /// Find a link by its slug.
    public func findBySlug(_ slug: String) throws -> Link? {
        ensureInitialized()
        return try queryOneLink("SELECT id, slug, name, project_path, \"column\", created_at, updated_at, last_activity, last_opened_at, source, manually_archived, prompt_body, prompt_image_paths, todoist_id, todoist_description, todoist_priority, todoist_due, todoist_labels, todoist_project_id, notes, project_id, assistant, last_tab, is_launching, sort_order, override_tmux, override_name, override_column FROM links WHERE slug = ?", bindings: [slug])
    }

    /// Add a new session path to an existing card, marking it as current.
    public func addSessionPath(linkId: String, sessionId: String, path: String?) throws {
        ensureInitialized()
        exec("BEGIN TRANSACTION")
        // Mark all existing paths as not current
        execParam("UPDATE session_paths SET is_current = 0 WHERE link_id = ?", bindings: [linkId])
        // Insert new path as current
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO session_paths (link_id, session_id, path, is_current, created_at) VALUES (?, ?, ?, 1, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            exec("ROLLBACK")
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
        if let path {
            sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, (dateToText(.now) as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) != SQLITE_DONE {
            exec("ROLLBACK")
            throw CoordinationStoreError.stepError(lastError)
        }
        exec("COMMIT")
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
    public func removeOrphans() throws {
        let fm = FileManager.default
        let links = try readLinks()
        for link in links {
            guard let path = link.sessionLink?.sessionPath else { continue }
            if !fm.fileExists(atPath: path) {
                try removeLink(id: link.id)
            }
        }
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
            INSERT OR REPLACE INTO links (
                id, slug, name, project_path, "column", created_at, updated_at,
                last_activity, last_opened_at, source, manually_archived,
                prompt_body, prompt_image_paths, todoist_id, todoist_description,
                todoist_priority, todoist_due, todoist_labels, todoist_project_id,
                notes, project_id, assistant, last_tab, is_launching, sort_order,
                override_tmux, override_name, override_column
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        var i: Int32 = 1
        bindText(stmt, &i, link.id)
        bindText(stmt, &i, link.sessionLink?.slug)
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
        bindInt(stmt, &i, link.manualOverrides.tmuxSession ? 1 : 0)
        bindInt(stmt, &i, link.manualOverrides.name ? 1 : 0)
        bindInt(stmt, &i, link.manualOverrides.column ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CoordinationStoreError.stepError(lastError)
        }

        // Insert session paths
        if let sl = link.sessionLink {
            // Previous sessions
            if let prevPaths = sl.previousSessionPaths {
                // We don't have session IDs for previous sessions stored in the old format.
                // Use the path filename (minus .jsonl) as a synthetic session ID.
                for prevPath in prevPaths {
                    let syntheticId = (prevPath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
                    try insertSessionPath(linkId: link.id, sessionId: syntheticId, path: prevPath, isCurrent: false)
                }
            }
            // Current session
            try insertSessionPath(linkId: link.id, sessionId: sl.sessionId, path: sl.sessionPath, isCurrent: true)
        }

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

    private func insertSessionPath(linkId: String, sessionId: String, path: String?, isCurrent: Bool) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO session_paths (link_id, session_id, path, is_current, created_at) VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
        if let path { sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int(stmt, 4, isCurrent ? 1 : 0)
        sqlite3_bind_text(stmt, 5, (dateToText(.now) as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoordinationStoreError.stepError(lastError) }
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
        // slug at column 1 — used for links table, hydrated into SessionLink
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
        let overrideTmux = sqlite3_column_int(stmt, 25) != 0
        let overrideName = sqlite3_column_int(stmt, 26) != 0
        let overrideColumn = sqlite3_column_int(stmt, 27) != 0

        return Link(
            id: id, name: name, projectPath: projectPath, column: column,
            createdAt: createdAt, updatedAt: updatedAt, lastActivity: lastActivity,
            lastOpenedAt: lastOpenedAt,
            manualOverrides: ManualOverrides(tmuxSession: overrideTmux, name: overrideName, column: overrideColumn),
            manuallyArchived: manuallyArchived, source: source,
            promptBody: promptBody, promptImagePaths: promptImagePaths,
            todoistId: todoistId, todoistDescription: todoistDescription,
            todoistPriority: todoistPriority, todoistDue: todoistDue,
            todoistLabels: todoistLabels, todoistProjectId: todoistProjectId,
            notes: notes, projectId: projectId,
            assistant: assistant, lastTab: lastTab, isLaunching: isLaunching, sortOrder: sortOrder
        )
    }

    private func hydrateSessionLink(linkId: String) throws -> SessionLink? {
        var sessions: [(sessionId: String, path: String?, isCurrent: Bool)] = []
        var slug: String?

        // Get slug from links table
        var slugStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT slug FROM links WHERE id = ?", -1, &slugStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(slugStmt, 1, (linkId as NSString).utf8String, -1, nil)
            if sqlite3_step(slugStmt) == SQLITE_ROW {
                slug = columnText(slugStmt, 0)
            }
        }
        sqlite3_finalize(slugStmt)

        // Get session paths
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT session_id, path, is_current FROM session_paths WHERE link_id = ? ORDER BY created_at", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (linkId as NSString).utf8String, -1, nil)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = String(cString: sqlite3_column_text(stmt, 0))
            let path = columnText(stmt, 1)
            let isCurrent = sqlite3_column_int(stmt, 2) != 0
            sessions.append((sid, path, isCurrent))
        }

        guard !sessions.isEmpty else { return nil }

        let current = sessions.first { $0.isCurrent } ?? sessions.last!
        let previous = sessions.filter { !$0.isCurrent }
        let prevPaths = previous.compactMap(\.path)

        return SessionLink(
            sessionId: current.sessionId,
            sessionPath: current.path,
            slug: slug,
            previousSessionPaths: prevPaths.isEmpty ? nil : prevPaths
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
        link.sessionLink = try hydrateSessionLink(linkId: link.id)
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
    case slugConflict(String)

    var errorDescription: String? {
        switch self {
        case .prepareError(let msg): "SQLite prepare failed: \(msg)"
        case .stepError(let msg): "SQLite step failed: \(msg)"
        case .slugConflict(let slug): "Slug '\(slug)' already belongs to another card"
        }
    }
}

// MARK: - Legacy Migration Container

private struct LinksContainer: Codable {
    let links: [Link]
}
