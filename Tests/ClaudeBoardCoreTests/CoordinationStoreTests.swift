import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("CoordinationStore")
struct CoordinationStoreTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Empty database returns empty links")
    func emptyDatabase() async throws {
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
            name: "Test session",
            projectPath: "/test/project",
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "abc-123")
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

        let link = Link(column: .backlog, sessionLink: SessionLink(sessionId: "new-1"))
        try await store.upsertLink(link)

        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].sessionId == "new-1")
    }

    @Test("Upsert updates existing link without affecting others")
    func upsertExisting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link1 = Link(name: "First", column: .backlog, sessionLink: SessionLink(sessionId: "s1"))
        let link2 = Link(name: "Second", column: .waiting, sessionLink: SessionLink(sessionId: "s2"))
        try await store.writeLinks([link1, link2])

        // Update only link1
        var updated = link1
        updated.name = "Updated"
        updated.manuallyArchived = true
        try await store.upsertLink(updated)

        // link2 should be untouched
        let links = try await store.readLinks()
        #expect(links.count == 2)
        let first = links.first { $0.id == link1.id }
        let second = links.first { $0.id == link2.id }
        #expect(first?.name == "Updated")
        #expect(first?.manuallyArchived == true)
        #expect(second?.name == "Second")
        #expect(second?.column == .waiting)
    }

    @Test("Remove link by session ID")
    func removeLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([
            Link(column: .backlog, sessionLink: SessionLink(sessionId: "a")),
            Link(column: .inProgress, sessionLink: SessionLink(sessionId: "b")),
        ])

        try await store.removeLink(sessionId: "a")
        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].sessionId == "b")
    }

    @Test("Remove link by card ID")
    func removeLinkById() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(column: .backlog, sessionLink: SessionLink(sessionId: "x"))
        try await store.upsertLink(link)

        try await store.removeLink(id: link.id)
        let links = try await store.readLinks()
        #expect(links.isEmpty)
    }

    @Test("Update link with closure")
    func updateLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.upsertLink(Link(column: .backlog, sessionLink: SessionLink(sessionId: "upd-1")))

        try await store.updateLink(sessionId: "upd-1") { link in
            link.column = .inProgress
            link.tmuxLink = TmuxLink(sessionName: "feat-login")
        }

        let link = try await store.linkForSession("upd-1")
        #expect(link?.column == .inProgress)
        #expect(link?.tmuxSession == "feat-login")
    }

    @Test("linkForSession returns correct link")
    func linkForSession() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([
            Link(name: "A", column: .done, sessionLink: SessionLink(sessionId: "s-a")),
            Link(name: "B", column: .done, sessionLink: SessionLink(sessionId: "s-b")),
        ])

        let found = try await store.linkForSession("s-b")
        #expect(found?.name == "B")

        let notFound = try await store.linkForSession("nonexistent")
        #expect(notFound == nil)
    }

    @Test("linkById returns correct link")
    func linkById() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(name: "Target", column: .done)
        try await store.upsertLink(link)

        let found = try await store.linkById(link.id)
        #expect(found?.name == "Target")

        let notFound = try await store.linkById("nonexistent")
        #expect(notFound == nil)
    }

    @Test("modifyLinks transforms all links atomically")
    func modifyLinks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([
            Link(name: "A", column: .backlog),
            Link(name: "B", column: .backlog),
        ])

        try await store.modifyLinks { links in
            for i in links.indices {
                links[i].column = .done
            }
        }

        let links = try await store.readLinks()
        #expect(links.allSatisfy { $0.column == .done })
    }

    @Test("removeOrphans deletes links with missing session files")
    func removeOrphans() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        // One link with existing file, one with missing file
        let existingPath = (dir as NSString).appendingPathComponent("exists.jsonl")
        try "data".write(toFile: existingPath, atomically: true, encoding: .utf8)

        try await store.writeLinks([
            Link(column: .done, sessionLink: SessionLink(sessionId: "s1", sessionPath: existingPath)),
            Link(column: .done, sessionLink: SessionLink(sessionId: "s2", sessionPath: "/nonexistent/missing.jsonl")),
        ])

        try await store.removeOrphans()
        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].sessionId == "s1")
    }

    @Test("Migrates from links.json on first use")
    func migratesFromJson() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Write a links.json file (old format)
        let jsonPath = (dir as NSString).appendingPathComponent("links.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let links = [
            Link(name: "Migrated", column: .waiting, manuallyArchived: true, sessionLink: SessionLink(sessionId: "mig-1")),
        ]
        let container = MigrationLinksContainer(links: links)
        let data = try encoder.encode(container)
        try data.write(to: URL(fileURLWithPath: jsonPath))

        // Create store — should auto-migrate
        let store = CoordinationStore(basePath: dir)
        let read = try await store.readLinks()
        #expect(read.count == 1)
        #expect(read[0].name == "Migrated")
        #expect(read[0].manuallyArchived == true)
        #expect(read[0].sessionId == "mig-1")

        // links.json should be deleted
        #expect(!FileManager.default.fileExists(atPath: jsonPath))
    }

    @Test("writeLinks replaces all links")
    func writeLinksReplaces() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([
            Link(name: "A", column: .done),
            Link(name: "B", column: .done),
        ])

        try await store.writeLinks([
            Link(name: "C", column: .done),
        ])

        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].name == "C")
    }
}

/// Mirror of the private LinksContainer for migration testing
private struct MigrationLinksContainer: Codable {
    let links: [Link]
}
