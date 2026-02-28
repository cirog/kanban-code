import Testing
import Foundation
@testable import KanbanCore

@Suite("CoordinationStore")
struct CoordinationStoreTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Empty file returns empty links")
    func emptyFile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)
        let links = try await store.readLinks()
        #expect(links.isEmpty)
    }

    @Test("Write and read round-trip")
    func roundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(
            sessionId: "abc-123",
            projectPath: "/test/project",
            column: .inProgress,
            name: "Test session"
        )
        try await store.writeLinks([link])

        let read = try await store.readLinks()
        #expect(read.count == 1)
        #expect(read[0].sessionId == "abc-123")
        #expect(read[0].column == .inProgress)
        #expect(read[0].name == "Test session")
    }

    @Test("Upsert creates new link")
    func upsertNew() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(sessionId: "new-1", column: .backlog)
        try await store.upsertLink(link)

        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].sessionId == "new-1")
    }

    @Test("Upsert updates existing link")
    func upsertExisting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(sessionId: "update-1", column: .backlog, name: "Original")
        try await store.upsertLink(link)

        link.name = "Updated"
        link.column = .inProgress
        try await store.upsertLink(link)

        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].name == "Updated")
        #expect(links[0].column == .inProgress)
    }

    @Test("Remove link by session ID")
    func removeLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([
            Link(sessionId: "a", column: .backlog),
            Link(sessionId: "b", column: .inProgress),
        ])

        try await store.removeLink(sessionId: "a")
        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].sessionId == "b")
    }

    @Test("Corrupted file returns empty and creates backup")
    func corruptionRecovery() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        // Write garbage
        let filePath = (dir as NSString).appendingPathComponent("links.json")
        try "not valid json {{{{".write(toFile: filePath, atomically: true, encoding: .utf8)

        let links = try await store.readLinks()
        #expect(links.isEmpty)

        // Backup should exist
        let backupPath = filePath + ".bkp"
        #expect(FileManager.default.fileExists(atPath: backupPath))
    }

    @Test("File is human-readable JSON")
    func humanReadable() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([Link(sessionId: "pretty", column: .done, name: "Test")])

        let filePath = (dir as NSString).appendingPathComponent("links.json")
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("\"pretty\""))
        #expect(content.contains("\n")) // pretty-printed
    }

    @Test("Update link with closure")
    func updateLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.upsertLink(Link(sessionId: "upd-1", column: .backlog))

        try await store.updateLink(sessionId: "upd-1") { link in
            link.column = .inProgress
            link.tmuxSession = "feat-login"
        }

        let link = try await store.linkForSession("upd-1")
        #expect(link?.column == .inProgress)
        #expect(link?.tmuxSession == "feat-login")
    }
}
