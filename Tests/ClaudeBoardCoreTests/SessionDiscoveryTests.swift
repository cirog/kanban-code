import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("ClaudeCodeSessionDiscovery")
struct SessionDiscoveryTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-discovery-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Discovers sessions from .jsonl files")
    func discoverFromJsonl() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create a fake project directory
        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-project")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write a .jsonl file
        let jsonlPath = (projectDir as NSString).appendingPathComponent("session-1.jsonl")
        try [
            #"{"type":"user","sessionId":"session-1","message":{"content":"Hello"},"cwd":"/Users/test/project"}"#,
            #"{"type":"assistant","sessionId":"session-1","message":{"content":[{"type":"text","text":"Hi there"}]}}"#,
        ].joined(separator: "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "session-1")
        #expect(sessions[0].firstPrompt == "Hello")
        #expect(sessions[0].messageCount >= 2)
    }

    @Test("Merges index metadata with .jsonl scan")
    func mergeIndexAndJsonl() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-myproject")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write index with summary
        let indexPath = (projectDir as NSString).appendingPathComponent("sessions-index.json")
        let indexData = #"{"sessions":[{"sessionId":"sess-2","summary":"Fix login flow"}]}"#
        try indexData.write(toFile: indexPath, atomically: true, encoding: .utf8)

        // Write .jsonl with the actual conversation
        let jsonlPath = (projectDir as NSString).appendingPathComponent("sess-2.jsonl")
        try #"{"type":"user","sessionId":"sess-2","message":{"content":"Fix the login"},"cwd":"/test"}"#
            .write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "sess-2")
        #expect(sessions[0].name == "Fix login flow") // from index
        #expect(sessions[0].firstPrompt == "Fix the login") // from .jsonl
    }

    @Test("Filters out zero-message sessions")
    func filterZeroMessages() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-empty")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write a .jsonl with only system lines
        let jsonlPath = (projectDir as NSString).appendingPathComponent("empty-sess.jsonl")
        try #"{"type":"file-history-snapshot","data":"stuff"}"#
            .write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.isEmpty)
    }

    @Test("Empty directory returns empty")
    func emptyDir() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.isEmpty)
    }

    @Test("Nonexistent directory returns empty")
    func nonexistentDir() async throws {
        let discovery = ClaudeCodeSessionDiscovery(claudeDir: "/nonexistent/path")
        let sessions = try await discovery.discoverSessions()
        #expect(sessions.isEmpty)
    }

    @Test("Skips .jsonl files older than 3 days")
    func skipsOldSessions() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-age")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Recent session (should be included)
        let recentPath = (projectDir as NSString).appendingPathComponent("recent.jsonl")
        try #"{"type":"user","sessionId":"recent","message":{"content":"Hi"},"cwd":"/test"}"#
            .write(toFile: recentPath, atomically: true, encoding: .utf8)

        // Old session — backdate mtime to 4 days ago
        let oldPath = (projectDir as NSString).appendingPathComponent("old.jsonl")
        try #"{"type":"user","sessionId":"old","message":{"content":"Hi"},"cwd":"/test"}"#
            .write(toFile: oldPath, atomically: true, encoding: .utf8)
        let threeDaysAgo = Date.now.addingTimeInterval(-3 * 24 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: threeDaysAgo],
            ofItemAtPath: oldPath
        )

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "recent")
    }

    @Test("Sessions sorted by modification time (newest first)")
    func sortedByModTime() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-sorted")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write two .jsonl files
        let path1 = (projectDir as NSString).appendingPathComponent("old-sess.jsonl")
        try #"{"type":"user","sessionId":"old-sess","message":{"content":"Old"},"cwd":"/test"}"#
            .write(toFile: path1, atomically: true, encoding: .utf8)

        // Small delay to ensure different mtime
        try await Task.sleep(for: .milliseconds(100))

        let path2 = (projectDir as NSString).appendingPathComponent("new-sess.jsonl")
        try #"{"type":"user","sessionId":"new-sess","message":{"content":"New"},"cwd":"/test"}"#
            .write(toFile: path2, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 2)
        #expect(sessions[0].id == "new-sess") // newest first
        #expect(sessions[1].id == "old-sess")
    }
}
