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

    // MARK: - Relational schema tests

    @Test("Relational: link with session paths round-trips all fields")
    func relationalFullRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(
            id: "card-1",
            name: "Test Card",
            projectPath: "/test/project",
            column: .inProgress,
            manualOverrides: ManualOverrides(name: true, column: true),
            manuallyArchived: false,
            source: .manual,
            promptBody: "Fix the bug",
            todoistId: "todo-123",
            sessionLink: SessionLink(
                sessionId: "session-1",
                sessionPath: "/path/to/s1.jsonl",
                slug: "test-slug"
            ),
            assistant: .claude
        )
        link.tmuxLink = TmuxLink(sessionName: "tmux-primary", extraSessions: ["tmux-shell"])
        link.queuedPrompts = [QueuedPrompt(id: "qp-1", body: "next task", sendAutomatically: true)]

        try await store.upsertLink(link)

        let loaded = try await store.readLinks()
        #expect(loaded.count == 1)
        let card = loaded[0]

        // Card-level fields
        #expect(card.id == "card-1")
        #expect(card.name == "Test Card")
        #expect(card.projectPath == "/test/project")
        #expect(card.column == .inProgress)
        #expect(card.manualOverrides.name == true)
        #expect(card.manualOverrides.column == true)
        #expect(card.source == .manual)
        #expect(card.promptBody == "Fix the bug")
        #expect(card.todoistId == "todo-123")
        #expect(card.effectiveAssistant == .claude)

        // Session data
        #expect(card.sessionLink?.sessionId == "session-1")
        #expect(card.sessionLink?.sessionPath == "/path/to/s1.jsonl")
        #expect(card.sessionLink?.slug == "test-slug")

        // Tmux data
        #expect(card.tmuxLink?.sessionName == "tmux-primary")
        #expect(card.tmuxLink?.extraSessions == ["tmux-shell"])

        // Queued prompts
        #expect(card.queuedPrompts?.count == 1)
        #expect(card.queuedPrompts?[0].body == "next task")
    }

    @Test("Relational: session chaining via previousSessionPaths round-trips")
    func relationalSessionChaining() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(
            id: "card-1",
            column: .done,
            sessionLink: SessionLink(
                sessionId: "session-3",
                sessionPath: "/path/to/s3.jsonl",
                slug: "my-slug",
                previousSessionPaths: ["/path/to/s1.jsonl", "/path/to/s2.jsonl"]
            )
        )
        try await store.upsertLink(link)

        let loaded = try await store.readLinks()
        #expect(loaded.count == 1)
        let card = loaded[0]
        #expect(card.sessionLink?.sessionId == "session-3")
        #expect(card.sessionLink?.sessionPath == "/path/to/s3.jsonl")
        #expect(card.sessionLink?.previousSessionPaths?.count == 2)
        #expect(card.sessionLink?.previousSessionPaths?.contains("/path/to/s1.jsonl") == true)
        #expect(card.sessionLink?.previousSessionPaths?.contains("/path/to/s2.jsonl") == true)
    }

    @Test("Relational: UNIQUE slug constraint prevents duplicate cards")
    func relationalSlugUniqueness() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var card1 = Link(id: "card-1", column: .done)
        card1.sessionLink = SessionLink(sessionId: "s1", sessionPath: "/s1.jsonl", slug: "same-slug")
        var card2 = Link(id: "card-2", column: .done)
        card2.sessionLink = SessionLink(sessionId: "s2", sessionPath: "/s2.jsonl", slug: "same-slug")

        try await store.upsertLink(card1)
        // Second card with same slug should throw
        var threw = false
        do {
            try await store.upsertLink(card2)
        } catch {
            threw = true
        }
        #expect(threw, "Expected UNIQUE constraint violation for duplicate slug")
    }

    @Test("Relational: findBySlug returns correct card")
    func relationalFindBySlug() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(id: "card-1", name: "Found", column: .done)
        link.sessionLink = SessionLink(sessionId: "s1", slug: "my-slug")
        try await store.upsertLink(link)

        let found = try await store.findBySlug("my-slug")
        #expect(found?.id == "card-1")
        #expect(found?.name == "Found")

        let notFound = try await store.findBySlug("nonexistent")
        #expect(notFound == nil)
    }

    @Test("Relational: linkSession links sessions and setCurrentSession marks current")
    func relationalLinkSession() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(id: "card-1", column: .done)
        link.sessionLink = SessionLink(sessionId: "s1", sessionPath: "/s1.jsonl", slug: "my-slug")
        try await store.upsertLink(link)

        // Link a new session to the same card
        try await store.linkSession(sessionId: "s2", linkId: "card-1", matchedBy: "slug", path: "/s2.jsonl")
        try await store.setCurrentSession(sessionId: "s2", forLink: "card-1")

        // s2 is now current
        let currentId = try await store.currentSessionId(forLink: "card-1")
        #expect(currentId == "s2")
        // Both sessions are linked to card-1
        let sessions = try await store.sessionIds(forLink: "card-1")
        #expect(sessions.count == 2)
        #expect(sessions.contains("s1"))
        #expect(sessions.contains("s2"))
        // Card owns s2
        let owner = try await store.cardIdForSession("s2")
        #expect(owner == "card-1")
    }

    @Test("Relational: CASCADE delete removes child rows")
    func relationalCascadeDelete() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(id: "card-1", column: .done)
        link.sessionLink = SessionLink(sessionId: "s1", sessionPath: "/s1.jsonl", slug: "slug")
        link.tmuxLink = TmuxLink(sessionName: "tmux-1")
        link.queuedPrompts = [QueuedPrompt(body: "test")]
        try await store.upsertLink(link)

        try await store.removeLink(id: "card-1")
        let links = try await store.readLinks()
        #expect(links.isEmpty)
        // Child rows should also be gone (CASCADE) — verified by re-inserting
        // a card with same slug (would fail if old session_paths row still had the slug)
        var link2 = Link(id: "card-2", column: .done)
        link2.sessionLink = SessionLink(sessionId: "s1", sessionPath: "/s1.jsonl", slug: "slug")
        try await store.upsertLink(link2) // Should not throw
        #expect(try await store.readLinks().count == 1)
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

