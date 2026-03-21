import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("Session Resolution")
struct SessionResolutionTests {

    // MARK: - CoordinationStore lookups (still used by doNotify/autoSend)

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
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
