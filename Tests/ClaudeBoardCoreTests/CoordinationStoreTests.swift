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
            slug: "test-slug"
        )
        try await store.writeLinks([link])

        let read = try await store.readLinks()
        #expect(read.count == 1)
        #expect(read[0].slug == "test-slug")
        #expect(read[0].column == .inProgress)
        #expect(read[0].name == "Test session")
    }

    @Test("Upsert creates new link")
    func upsertNew() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(column: .backlog, slug: "new-1")
        try await store.upsertLink(link)

        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].slug == "new-1")
    }

    @Test("Upsert updates existing link without affecting others")
    func upsertExisting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link1 = Link(name: "First", column: .backlog, slug: "s1")
        let link2 = Link(name: "Second", column: .waiting, slug: "s2")
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

    @Test("Remove link by session ID via session_links")
    func removeLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let linkA = Link(column: .backlog, slug: "a")
        let linkB = Link(column: .inProgress, slug: "b")
        try await store.writeLinks([linkA, linkB])
        // Link sessions
        try await store.linkSession(sessionId: "sess-a", linkId: linkA.id, matchedBy: "test", path: nil)
        try await store.linkSession(sessionId: "sess-b", linkId: linkB.id, matchedBy: "test", path: nil)

        try await store.removeLink(sessionId: "sess-a")
        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].slug == "b")
    }

    @Test("Remove link by card ID")
    func removeLinkById() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(column: .backlog, slug: "x")
        try await store.upsertLink(link)

        try await store.removeLink(id: link.id)
        let links = try await store.readLinks()
        #expect(links.isEmpty)
    }

    @Test("Update link with closure via session ID")
    func updateLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(column: .backlog, slug: "upd-slug")
        try await store.upsertLink(link)
        try await store.linkSession(sessionId: "sess-upd-1", linkId: link.id, matchedBy: "test", path: nil)

        try await store.updateLink(sessionId: "sess-upd-1") { link in
            link.column = .inProgress
            link.tmuxLink = TmuxLink(sessionName: "feat-login")
        }

        let found = try await store.linkForSession("sess-upd-1")
        #expect(found?.column == .inProgress)
        #expect(found?.tmuxSession == "feat-login")
    }

    @Test("linkForSession returns correct link")
    func linkForSession() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let linkA = Link(name: "A", column: .done, slug: "a")
        let linkB = Link(name: "B", column: .done, slug: "b")
        try await store.writeLinks([linkA, linkB])
        try await store.linkSession(sessionId: "s-a", linkId: linkA.id, matchedBy: "test", path: nil)
        try await store.linkSession(sessionId: "s-b", linkId: linkB.id, matchedBy: "test", path: nil)

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

    @Test("removeOrphans is a no-op (session paths in session_links)")
    func removeOrphans() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([
            Link(column: .done, slug: "s1"),
            Link(column: .done, slug: "s2"),
        ])

        // removeOrphans is now a no-op
        try await store.removeOrphans()
        let links = try await store.readLinks()
        #expect(links.count == 2)
    }

    // MARK: - Relational schema tests

    @Test("Relational: link with slug round-trips all fields")
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
            slug: "test-slug",
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
        #expect(card.slug == "test-slug")

        // Tmux data
        #expect(card.tmuxLink?.sessionName == "tmux-primary")
        #expect(card.tmuxLink?.extraSessions == ["tmux-shell"])

        // Queued prompts
        #expect(card.queuedPrompts?.count == 1)
        #expect(card.queuedPrompts?[0].body == "next task")
    }

    @Test("Relational: findBySlug returns correct card")
    func relationalFindBySlug() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(id: "card-1", name: "Found", column: .done)
        link.slug = "my-slug"
        try await store.upsertLink(link)

        let found = try await store.findBySlug("my-slug")
        #expect(found?.id == "card-1")
        #expect(found?.name == "Found")

        let notFound = try await store.findBySlug("nonexistent")
        #expect(notFound == nil)
    }

    @Test("Relational: CASCADE delete removes child rows")
    func relationalCascadeDelete() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(id: "card-1", column: .done)
        link.slug = "slug"
        link.tmuxLink = TmuxLink(sessionName: "tmux-1")
        link.queuedPrompts = [QueuedPrompt(body: "test")]
        try await store.upsertLink(link)

        try await store.removeLink(id: "card-1")
        let links = try await store.readLinks()
        #expect(links.isEmpty)
        // Child rows should also be gone (CASCADE) — verified by re-inserting
        // a card with same slug (would fail if old row still had the slug)
        var link2 = Link(id: "card-2", column: .done)
        link2.slug = "slug"
        try await store.upsertLink(link2) // Should not throw
        #expect(try await store.readLinks().count == 1)
    }

    // MARK: - Chain segment queries

    @Test("chainSegments returns sessions for a card")
    func chainSegmentsForCard() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(id: "card-1", column: .waiting, source: .manual)
        try await store.writeLinks([link], associations: [
            CardReconciler.SessionAssociation(sessionId: "s1", cardId: "card-1", matchedBy: "tmux", path: "/s1.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s2", cardId: "card-1", matchedBy: "tmux", path: "/s2.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s3", cardId: "card-1", matchedBy: "discovered", path: "/s3.jsonl"),
        ])

        let segments = try await store.chainSegments(forCardId: "card-1")
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.cardId == "card-1" })
    }

    @Test("chainSegments respects limit")
    func chainSegmentsLimit() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(id: "card-1", column: .waiting, source: .manual)
        try await store.writeLinks([link], associations: [
            CardReconciler.SessionAssociation(sessionId: "s1", cardId: "card-1", matchedBy: "tmux", path: "/s1.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s2", cardId: "card-1", matchedBy: "tmux", path: "/s2.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s3", cardId: "card-1", matchedBy: "tmux", path: "/s3.jsonl"),
        ])

        let segments = try await store.chainSegments(forCardId: "card-1", limit: 2)
        #expect(segments.count == 2)
    }

    @Test("chainSegmentCount returns total for a card")
    func chainSegmentCount() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(id: "card-1", column: .waiting, source: .manual)
        try await store.writeLinks([link], associations: [
            CardReconciler.SessionAssociation(sessionId: "s1", cardId: "card-1", matchedBy: "tmux", path: "/s1.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s2", cardId: "card-1", matchedBy: "tmux", path: "/s2.jsonl"),
        ])

        #expect(try await store.chainSegmentCount(forCardId: "card-1") == 2)
        #expect(try await store.chainSegmentCount(forCardId: "card-other") == 0)
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
