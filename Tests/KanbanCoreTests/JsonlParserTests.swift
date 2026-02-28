import Testing
import Foundation
@testable import KanbanCore

@Suite("JsonlParser")
struct JsonlParserTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-jsonl-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func writeJsonl(_ dir: String, _ name: String, _ lines: [String]) throws -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("Extracts metadata from a simple session")
    func simpleSession() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "abc-123.jsonl", [
            #"{"type":"user","sessionId":"abc-123","message":{"content":"Fix the login bug"},"cwd":"/Users/test/project","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"abc-123","message":{"content":[{"type":"text","text":"I'll fix that."}]}}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata != nil)
        #expect(metadata?.sessionId == "abc-123")
        #expect(metadata?.firstPrompt == "Fix the login bug")
        #expect(metadata?.projectPath == "/Users/test/project")
        #expect(metadata?.messageCount == 2)
    }

    @Test("Handles content block array format")
    func contentBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "block-1.jsonl", [
            #"{"type":"user","sessionId":"block-1","message":{"content":[{"type":"text","text":"Hello world"}]},"cwd":"/test"}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata?.firstPrompt == "Hello world")
    }

    @Test("Skips file-history-snapshot lines")
    func skipsNonMessageLines() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "skip-1.jsonl", [
            #"{"type":"file-history-snapshot","data":"lots of stuff"}"#,
            #"{"type":"user","sessionId":"skip-1","message":{"content":"The real message"},"cwd":"/test"}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata != nil)
        #expect(metadata?.firstPrompt == "The real message")
        #expect(metadata?.messageCount == 1)
    }

    @Test("Returns nil for empty file")
    func emptyFile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "empty.jsonl", [""])
        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata == nil)
    }

    @Test("Returns nil for file with only system lines")
    func systemOnly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "sys.jsonl", [
            #"{"type":"file-history-snapshot","data":"stuff"}"#,
            #"{"type":"progress","data":"loading"}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata == nil)
    }

    @Test("Returns nil for nonexistent file")
    func nonexistent() async throws {
        let metadata = try await JsonlParser.extractMetadata(from: "/nonexistent/path.jsonl")
        #expect(metadata == nil)
    }

    @Test("Decode directory name to path")
    func decodeDirectoryName() {
        let decoded = JsonlParser.decodeDirectoryName("-Users-rchaves-Projects-remote-langwatch")
        #expect(decoded == "/Users/rchaves/Projects/remote/langwatch")
    }

    @Test("Decode directory name preserves root slash")
    func decodeDirectoryNameRoot() {
        let decoded = JsonlParser.decodeDirectoryName("-home-ubuntu-Projects")
        #expect(decoded == "/home/ubuntu/Projects")
    }
}
