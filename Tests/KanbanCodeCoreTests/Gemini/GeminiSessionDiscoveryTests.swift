import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("GeminiSessionDiscovery")
struct GeminiSessionDiscoveryTests {

    // MARK: - Helpers

    private func makeTempGeminiDir() throws -> String {
        let base = "/tmp/kanban-test-gemini-discovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func createSessionFile(
        at dir: String,
        slug: String,
        sessionId: String,
        content: String? = nil
    ) throws -> String {
        let chatsDir = "\(dir)/tmp/\(slug)/chats"
        try FileManager.default.createDirectory(atPath: chatsDir, withIntermediateDirectories: true)

        let json = content ?? """
        {
            "sessionId": "\(sessionId)",
            "messages": [
                {"type": "user", "content": [{"text": "Hello from \(sessionId)"}]},
                {"type": "gemini", "content": "Response"}
            ]
        }
        """

        let filePath = "\(chatsDir)/session-\(sessionId).json"
        try json.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    private func writeProjectsJson(at dir: String, mapping: [String: String]) throws {
        let projectsJson: [String: Any] = ["projects": mapping]
        let data = try JSONSerialization.data(withJSONObject: projectsJson)
        try data.write(to: URL(fileURLWithPath: "\(dir)/projects.json"))
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Discovery

    @Test("Discovers sessions from tmp directory")
    func discoversSessions() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        let _ = try createSessionFile(at: dir, slug: "my-project", sessionId: "sess-001")
        let _ = try createSessionFile(at: dir, slug: "my-project", sessionId: "sess-002")

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.assistant == .gemini })
    }

    @Test("Sessions are sorted by modification time descending")
    func sortedByModifiedTime() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        let path1 = try createSessionFile(at: dir, slug: "proj", sessionId: "old-session")
        let _ = try createSessionFile(at: dir, slug: "proj", sessionId: "new-session")

        // Make first file older
        let oldDate = Date.now.addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path1)

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 2)
        #expect(sessions[0].id == "new-session")
        #expect(sessions[1].id == "old-session")
    }

    @Test("Maps project path from projects.json")
    func mapsProjectPath() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        try writeProjectsJson(at: dir, mapping: [
            "/Users/dev/my-project": "my-project-slug"
        ])

        let _ = try createSessionFile(at: dir, slug: "my-project-slug", sessionId: "mapped-sess")

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].projectPath == "/Users/dev/my-project")
    }

    @Test("Returns nil projectPath when slug not in projects.json")
    func noMappingNilProjectPath() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        // No projects.json
        let _ = try createSessionFile(at: dir, slug: "unknown-slug", sessionId: "unmapped")

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].projectPath == nil)
    }

    @Test("Returns empty for non-existent gemini dir")
    func nonExistentDir() async throws {
        let discovery = GeminiSessionDiscovery(geminiDir: "/nonexistent/gemini/dir")
        let sessions = try await discovery.discoverSessions()
        #expect(sessions.isEmpty)
    }

    @Test("Ignores non-session files")
    func ignoresNonSessionFiles() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        // Create a session file
        let _ = try createSessionFile(at: dir, slug: "proj", sessionId: "valid")

        // Create a non-session file
        let chatsDir = "\(dir)/tmp/proj/chats"
        try "not a session".write(toFile: "\(chatsDir)/notes.txt", atomically: true, encoding: .utf8)
        try "{}".write(toFile: "\(chatsDir)/config.json", atomically: true, encoding: .utf8)

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "valid")
    }

    @Test("Skips unparseable session files")
    func skipsUnparseable() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        // Valid session
        let _ = try createSessionFile(at: dir, slug: "proj", sessionId: "good")

        // Bad session file
        let chatsDir = "\(dir)/tmp/proj/chats"
        try "invalid json content".write(toFile: "\(chatsDir)/session-bad.json", atomically: true, encoding: .utf8)

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "good")
    }

    @Test("Discovers sessions from multiple project slugs")
    func multipleProjects() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        let _ = try createSessionFile(at: dir, slug: "project-a", sessionId: "sess-a")
        let _ = try createSessionFile(at: dir, slug: "project-b", sessionId: "sess-b")

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 2)
        let ids = Set(sessions.map(\.id))
        #expect(ids.contains("sess-a"))
        #expect(ids.contains("sess-b"))
    }

    @Test("Session stores jsonlPath pointing to the JSON file")
    func sessionHasJsonlPath() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        let filePath = try createSessionFile(at: dir, slug: "proj", sessionId: "path-test")

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].jsonlPath == filePath)
    }

    @Test("Session extracts firstPrompt from content")
    func sessionExtractsFirstPrompt() async throws {
        let dir = try makeTempGeminiDir()
        defer { cleanup(dir) }

        let _ = try createSessionFile(at: dir, slug: "proj", sessionId: "prompt-test")

        let discovery = GeminiSessionDiscovery(geminiDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions[0].firstPrompt == "Hello from prompt-test")
    }
}
