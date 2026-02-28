import Testing
import Foundation
@testable import KanbanCore

@Suite("TranscriptReader")
struct TranscriptReaderTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-transcript-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Reads user and assistant turns")
    func readTurns() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi there! How can I help?"}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Fix the bug"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 3)
        #expect(turns[0].role == "user")
        #expect(turns[0].textPreview == "Hello")
        #expect(turns[0].timestamp == "2026-01-01T00:00:00Z")
        #expect(turns[1].role == "assistant")
        #expect(turns[1].textPreview == "Hi there! How can I help?")
        #expect(turns[2].role == "user")
        #expect(turns[2].textPreview == "Fix the bug")
    }

    @Test("Skips non-message lines")
    func skipsNonMessages() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"file-history-snapshot","data":"lots of data"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test"}"#,
            #"{"type":"progress","data":"loading"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].textPreview == "Hello")
    }

    @Test("Returns empty for nonexistent file")
    func nonexistent() async throws {
        let turns = try await TranscriptReader.readTurns(from: "/nonexistent/path.jsonl")
        #expect(turns.isEmpty)
    }

    @Test("Handles tool-use-only assistant responses")
    func toolUseOnly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].textPreview == "(tool use)")
    }

    @Test("Line numbers are correct")
    func lineNumbers() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"file-history-snapshot","data":"stuff"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].lineNumber == 2) // first message line is line 2
        #expect(turns[1].lineNumber == 3)
    }
}
