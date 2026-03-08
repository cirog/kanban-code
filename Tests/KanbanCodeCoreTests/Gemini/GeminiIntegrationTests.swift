import Testing
import Foundation
@testable import KanbanCodeCore

/// Integration tests that use the real Gemini CLI and filesystem.
/// These are disabled by default to avoid API costs in CI.
/// To run locally: swift test --filter GeminiIntegrationTests
///
/// Prerequisites:
/// - `gemini` CLI installed (`npm install -g @google/gemini-cli`)
/// - `~/.gemini/` directory exists with at least one session
@Suite("Gemini Integration", .disabled("Requires real Gemini CLI and sessions — run manually"))
struct GeminiIntegrationTests {

    // MARK: - Real Discovery

    @Test("Discovers real Gemini sessions from ~/.gemini")
    func discoverRealSessions() async throws {
        let discovery = GeminiSessionDiscovery()
        let sessions = try await discovery.discoverSessions()

        // Should find at least one session if gemini has been used
        #expect(!sessions.isEmpty, "Expected at least one Gemini session in ~/.gemini")

        for session in sessions {
            #expect(session.assistant == .gemini)
            #expect(!session.id.isEmpty)
            #expect(session.jsonlPath != nil)
        }
    }

    @Test("Real session files are parseable")
    func realSessionsParseable() async throws {
        let discovery = GeminiSessionDiscovery()
        let sessions = try await discovery.discoverSessions()

        guard let session = sessions.first, let path = session.jsonlPath else {
            Issue.record("No sessions found to test parsing")
            return
        }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)
        #expect(!turns.isEmpty)

        // Verify basic structure
        for turn in turns {
            #expect(["user", "assistant", "system"].contains(turn.role))
            #expect(!turn.textPreview.isEmpty)
        }
    }

    @Test("Real session metadata extraction works")
    func realMetadataExtraction() async throws {
        let discovery = GeminiSessionDiscovery()
        let sessions = try await discovery.discoverSessions()

        guard let session = sessions.first, let path = session.jsonlPath else {
            Issue.record("No sessions found")
            return
        }

        let metadata = try GeminiSessionParser.extractMetadata(from: path)
        #expect(metadata != nil)
        #expect(metadata?.sessionId == session.id)
        #expect((metadata?.messageCount ?? 0) > 0)
    }

    @Test("Real session search works")
    func realSessionSearch() async throws {
        let discovery = GeminiSessionDiscovery()
        let sessions = try await discovery.discoverSessions()

        let paths = sessions.compactMap(\.jsonlPath)
        guard !paths.isEmpty else {
            Issue.record("No session files found")
            return
        }

        let store = GeminiSessionStore()
        // Search for a common programming term
        let results = try await store.searchSessions(query: "function", paths: paths)
        // May or may not find results, but should not crash
        _ = results
    }

    @Test("Real session fork and cleanup")
    func realSessionFork() async throws {
        let discovery = GeminiSessionDiscovery()
        let sessions = try await discovery.discoverSessions()

        guard let session = sessions.first, let path = session.jsonlPath else {
            Issue.record("No sessions found")
            return
        }

        let targetDir = "/tmp/kanban-test-gemini-fork-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: targetDir) }

        let store = GeminiSessionStore()
        let newId = try await store.forkSession(sessionPath: path, targetDirectory: targetDir)

        #expect(!newId.isEmpty)
        #expect(newId != session.id)

        // Verify the forked file exists and is parseable
        let newPath = (targetDir as NSString).appendingPathComponent("session-forked-\(newId).json")
        #expect(FileManager.default.fileExists(atPath: newPath))

        let forkedSession = try GeminiSessionParser.parseSession(from: newPath)
        #expect(forkedSession?.sessionId == newId)
    }

    // MARK: - Activity Detection on Real Files

    @Test("Activity detector classifies real session files")
    func realActivityDetection() async throws {
        let discovery = GeminiSessionDiscovery()
        let sessions = try await discovery.discoverSessions()

        guard !sessions.isEmpty else {
            Issue.record("No sessions found")
            return
        }

        var sessionPaths: [String: String] = [:]
        for session in sessions.prefix(5) {
            if let path = session.jsonlPath {
                sessionPaths[session.id] = path
            }
        }

        let detector = GeminiActivityDetector()
        let states = await detector.pollActivity(sessionPaths: sessionPaths)

        #expect(states.count == sessionPaths.count)
        for (_, state) in states {
            #expect([.activelyWorking, .needsAttention, .idleWaiting, .ended, .stale].contains(state))
        }
    }

    // MARK: - LaunchSession with Gemini

    @Test("LaunchSession builds correct Gemini command")
    func launchGeminiCommand() async throws {
        // Use a recording mock to verify the command without actually launching
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test-gemini-int",
            projectPath: "/tmp",
            prompt: "test prompt",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: true,
            assistant: .gemini
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("gemini"))
        #expect(cmd.contains("--yolo"))
        #expect(!cmd.contains("--worktree"))
    }

    // Mock for command recording
    final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
        var lastCommand: String?
        func createSession(name: String, path: String, command: String?) async throws { lastCommand = command }
        func killSession(name: String) async throws {}
        func listSessions() async throws -> [TmuxSession] { [] }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func capturePane(sessionName: String) async throws -> String { "" }
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
    }
}
