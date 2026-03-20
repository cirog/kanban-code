import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("Session Resolution")
struct SessionResolutionTests {

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Write a minimal .jsonl file with a slug in the init message.
    /// Includes a user message so extractMetadata doesn't discard it (messageCount > 0).
    func writeJsonl(at path: String, slug: String) throws {
        let lines = """
        {"type":"system","slug":"\(slug)","cwd":"/test"}
        {"type":"user","message":{"content":"hello"},"slug":"\(slug)"}
        """
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("resolveLink finds card by slug when sessionId is unknown")
    func resolveLinkSlugFallback() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        // Card exists with old session, slug "my-slug"
        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session-id",
                sessionPath: "/old/path.jsonl",
                slug: "my-slug"
            )
        )
        try await store.writeLinks([card])

        // New session .jsonl file with same slug
        let jsonlPath = (dir as NSString).appendingPathComponent("new-session.jsonl")
        try writeJsonl(at: jsonlPath, slug: "my-slug")

        // linkForSession with new ID returns nil
        let directLookup = try await store.linkForSession("new-session-id")
        #expect(directLookup == nil)

        // resolveLink should find the card via slug fallback
        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "new-session-id",
            transcriptPath: jsonlPath,
            coordinationStore: store
        )
        #expect(resolved != nil)
        #expect(resolved?.id == card.id)

        // Session should now be registered — future lookups hit fast path
        let fastPath = try await store.linkForSession("new-session-id")
        #expect(fastPath != nil)
        #expect(fastPath?.id == card.id)
    }

    @Test("resolveLink returns nil when sessionId unknown and no transcript path")
    func resolveLinkNoTranscript() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "old-id", slug: "slug-1")
        )
        try await store.writeLinks([card])

        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "unknown-id",
            transcriptPath: nil,
            coordinationStore: store
        )
        #expect(resolved == nil)
    }

    @Test("resolveLink returns nil when transcript has no slug")
    func resolveLinkNoSlugInTranscript() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "old-id", slug: "slug-1")
        )
        try await store.writeLinks([card])

        // Write a .jsonl with no slug field
        let jsonlPath = (dir as NSString).appendingPathComponent("no-slug.jsonl")
        try """
        {"type":"system","cwd":"/test"}
        """.write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "unknown-id",
            transcriptPath: jsonlPath,
            coordinationStore: store
        )
        #expect(resolved == nil)
    }

    // MARK: - Tmux-based resolution

    @Test("resolveLink finds card by tmux session name when slug is missing")
    func resolveLinkTmuxFallback() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        // Card with tmux session but NO slug (predates slug support)
        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session-id",
                sessionPath: "/old/path.jsonl"
            ),
            tmuxLink: TmuxLink(sessionName: "ciro-card_ABC123")
        )
        try await store.writeLinks([card])

        // New session — no slug in transcript, but same tmux session
        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "new-session-id",
            transcriptPath: nil,
            tmuxSessionName: "ciro-card_ABC123",
            coordinationStore: store
        )
        #expect(resolved != nil)
        #expect(resolved?.id == card.id)

        // Session should now be registered — future lookups hit fast path
        let fastPath = try await store.linkForSession("new-session-id")
        #expect(fastPath != nil)
        #expect(fastPath?.id == card.id)
    }

    @Test("resolveLink prefers slug over tmux when both available")
    func resolveLinkSlugBeforeTmux() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        // Two cards: one with slug, one with tmux
        let slugCard = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "slug-session",
                sessionPath: "/slug/path.jsonl",
                slug: "correct-slug"
            )
        )
        let tmuxCard = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "tmux-session",
                sessionPath: "/tmux/path.jsonl"
            ),
            tmuxLink: TmuxLink(sessionName: "ciro-card_WRONG")
        )
        try await store.writeLinks([slugCard, tmuxCard])

        // Transcript has the slug → should resolve to slugCard, not tmuxCard
        let jsonlPath = (dir as NSString).appendingPathComponent("new.jsonl")
        try writeJsonl(at: jsonlPath, slug: "correct-slug")

        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "brand-new-session",
            transcriptPath: jsonlPath,
            tmuxSessionName: "ciro-card_WRONG",
            coordinationStore: store
        )
        #expect(resolved?.id == slugCard.id)
    }

    @Test("resolveLink returns nil when tmux name is empty")
    func resolveLinkEmptyTmux() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "old-id"),
            tmuxLink: TmuxLink(sessionName: "ciro-card_XYZ")
        )
        try await store.writeLinks([card])

        // Empty tmux name should not match
        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "unknown-id",
            transcriptPath: nil,
            tmuxSessionName: "",
            coordinationStore: store
        )
        #expect(resolved == nil)
    }

    @Test("findByTmuxSessionName returns link for known tmux session")
    func findByTmuxSessionName() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let card = Link(
            column: .inProgress,
            source: .discovered,
            tmuxLink: TmuxLink(sessionName: "ciro-card_TEST99")
        )
        try await store.writeLinks([card])

        let found = try await store.findByTmuxSessionName("ciro-card_TEST99")
        #expect(found != nil)
        #expect(found?.id == card.id)
    }

    @Test("findByTmuxSessionName returns nil for unknown tmux session")
    func findByTmuxSessionNameNotFound() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let card = Link(
            column: .inProgress,
            source: .discovered,
            tmuxLink: TmuxLink(sessionName: "ciro-card_EXISTING")
        )
        try await store.writeLinks([card])

        let found = try await store.findByTmuxSessionName("ciro-card_NOPE")
        #expect(found == nil)
    }

    @Test("HookEvent parses tmuxSession field")
    func hookEventTmuxParsing() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let hookStore = HookEventStore(basePath: dir)
        let filePath = await hookStore.path

        // Write a hook event with tmuxSession
        let json = """
        {"sessionId":"sess-123","event":"SessionStart","timestamp":"2026-03-20T10:00:00Z","transcriptPath":"/path/to/transcript.jsonl","tmuxSession":"ciro-card_ABC"}
        """
        try json.write(toFile: filePath, atomically: true, encoding: .utf8)

        let events = try await hookStore.readAllEvents()
        #expect(events.count == 1)
        #expect(events[0].tmuxSessionName == "ciro-card_ABC")
        #expect(events[0].sessionId == "sess-123")
        #expect(events[0].eventName == "SessionStart")
    }

    @Test("HookEvent treats empty tmuxSession as nil")
    func hookEventEmptyTmux() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let hookStore = HookEventStore(basePath: dir)
        let filePath = await hookStore.path

        let json = """
        {"sessionId":"sess-456","event":"Stop","timestamp":"2026-03-20T10:00:00Z","transcriptPath":"","tmuxSession":""}
        """
        try json.write(toFile: filePath, atomically: true, encoding: .utf8)

        let events = try await hookStore.readAllEvents()
        #expect(events.count == 1)
        #expect(events[0].tmuxSessionName == nil)
    }
}
