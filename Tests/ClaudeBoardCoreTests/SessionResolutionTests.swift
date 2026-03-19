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
}
