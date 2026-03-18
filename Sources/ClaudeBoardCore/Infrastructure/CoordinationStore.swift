import Foundation
import SQLite3

/// Persistent store for Link records using SQLite.
/// Row-level atomic updates — no read-all/write-all races.
public actor CoordinationStore {
    private let dbPath: String
    private let basePath: String
    nonisolated(unsafe) private var db: OpaquePointer?
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
        createTable()
        migrateFromJson()
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
        // WAL mode for better concurrent read performance
        exec("PRAGMA journal_mode=WAL")
    }

    private func createTable() {
        exec("""
            CREATE TABLE IF NOT EXISTS links (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                data BLOB NOT NULL
            )
        """)
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_session_id ON links(session_id)")
    }

    /// One-time migration: import links.json into SQLite, then delete the JSON file.
    private func migrateFromJson() {
        let jsonPath = (basePath as NSString).appendingPathComponent("links.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: jsonPath) else { return }
        // Don't migrate if we already have data
        if let count = queryInt("SELECT COUNT(*) FROM links"), count > 0 { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            let container = try decoder.decode(LinksContainer.self, from: data)
            exec("BEGIN TRANSACTION")
            for link in container.links {
                try insertLink(link)
            }
            exec("COMMIT")
            // Clean cut — delete JSON file
            try fm.removeItem(atPath: jsonPath)
            // Also clean up backup files
            for suffix in [".bkp", ".tmp"] {
                try? fm.removeItem(atPath: jsonPath + suffix)
            }
            ClaudeBoardLog.info("sqlite", "Migrated \(container.links.count) links from links.json to SQLite")
        } catch {
            exec("ROLLBACK")
            ClaudeBoardLog.warn("sqlite", "Migration from links.json failed: \(error)")
        }
    }

    // MARK: - Public API

    /// Read all links from the database.
    public func readLinks() throws -> [Link] {
        ensureInitialized()
        var links: [Link] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM links", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let size = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: size)
                if let link = try? decoder.decode(Link.self, from: data) {
                    links.append(link)
                }
            }
        }
        return links
    }

    /// Write all links (replaces entire table contents).
    public func writeLinks(_ links: [Link]) throws {
        ensureInitialized()
        exec("BEGIN TRANSACTION")
        exec("DELETE FROM links")
        do {
            for link in links {
                try insertLink(link)
            }
            exec("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    /// Get a single link by its id.
    public func linkById(_ id: String) throws -> Link? {
        ensureInitialized()
        return try queryLink("SELECT data FROM links WHERE id = ?", bindings: [id])
    }

    /// Get a single link by session ID.
    public func linkForSession(_ sessionId: String) throws -> Link? {
        ensureInitialized()
        return try queryLink("SELECT data FROM links WHERE session_id = ?", bindings: [sessionId])
    }

    /// Upsert a link: insert or replace by id. Touches only one row.
    public func upsertLink(_ link: Link) throws {
        ensureInitialized()
        let data = try encoder.encode(link)
        let sessionId = link.sessionLink?.sessionId
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO links (id, session_id, data) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (link.id as NSString).utf8String, -1, nil)
        if let sid = sessionId {
            sqlite3_bind_text(stmt, 2, (sid as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_blob(stmt, 3, (data as NSData).bytes, Int32(data.count), nil)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw CoordinationStoreError.stepError(lastError)
        }
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

    /// Remove a link by its id.
    public func removeLink(id: String) throws {
        exec("DELETE FROM links WHERE id = '\(id)'")
    }

    /// Remove a link by session ID.
    public func removeLink(sessionId: String) throws {
        exec("DELETE FROM links WHERE session_id = '\(sessionId)'")
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

    // MARK: - Private Helpers

    private func insertLink(_ link: Link) throws {
        let data = try encoder.encode(link)
        let sessionId = link.sessionLink?.sessionId
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO links (id, session_id, data) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoordinationStoreError.prepareError(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (link.id as NSString).utf8String, -1, nil)
        if let sid = sessionId {
            sqlite3_bind_text(stmt, 2, (sid as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_blob(stmt, 3, (data as NSData).bytes, Int32(data.count), nil)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw CoordinationStoreError.stepError(lastError)
        }
    }

    private func queryLink(_ sql: String, bindings: [String]) throws -> Link? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, val) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (val as NSString).utf8String, -1, nil)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let size = Int(sqlite3_column_bytes(stmt, 0))
        let data = Data(bytes: blob, count: size)
        return try decoder.decode(Link.self, from: data)
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

// MARK: - Migration Container

private struct LinksContainer: Codable {
    let links: [Link]
}
