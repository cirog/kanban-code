import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("TranscriptConcatenation")
struct TranscriptConcatenationTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-concat-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - streamAllTurns across multiple files

    @Test("streamAllTurns concatenates turns from multiple files in order")
    func streamConcatenatesMultipleFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path1 = (dir as NSString).appendingPathComponent("session1.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello from session 1"},"cwd":"/test","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Reply in session 1"}]}}"#,
        ].joined(separator: "\n").write(toFile: path1, atomically: true, encoding: .utf8)

        let path2 = (dir as NSString).appendingPathComponent("session2.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello from session 2"},"cwd":"/test","timestamp":"2026-01-02T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Reply in session 2"}]}}"#,
        ].joined(separator: "\n").write(toFile: path2, atomically: true, encoding: .utf8)

        // Concatenate turns from both files (simulating what loadPrompts should do)
        var allTurns: [ConversationTurn] = []
        for path in [path1, path2] {
            for await turn in TranscriptReader.streamAllTurns(from: path) {
                allTurns.append(turn)
            }
        }

        #expect(allTurns.count == 4)
        #expect(allTurns[0].textPreview == "Hello from session 1")
        #expect(allTurns[1].textPreview == "Reply in session 1")
        #expect(allTurns[2].textPreview == "Hello from session 2")
        #expect(allTurns[3].textPreview == "Reply in session 2")
    }

    @Test("User prompt filtering works across concatenated files")
    func userPromptsAcrossConcatenatedFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path1 = (dir as NSString).appendingPathComponent("session1.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"First prompt"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Response 1"}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"result data"}]}}"#,
        ].joined(separator: "\n").write(toFile: path1, atomically: true, encoding: .utf8)

        let path2 = (dir as NSString).appendingPathComponent("session2.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Second prompt"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Response 2"}]}}"#,
        ].joined(separator: "\n").write(toFile: path2, atomically: true, encoding: .utf8)

        // Concatenate and filter — same logic as loadPrompts
        var allTurns: [ConversationTurn] = []
        for path in [path1, path2] {
            for await turn in TranscriptReader.streamAllTurns(from: path) {
                allTurns.append(turn)
            }
        }

        let userPrompts = allTurns.filter { turn in
            turn.role == "user" && !turn.textPreview.hasPrefix("[tool result")
        }

        // Should find prompts from BOTH files, excluding tool results
        #expect(userPrompts.count == 2)
        #expect(userPrompts[0].textPreview == "First prompt")
        #expect(userPrompts[1].textPreview == "Second prompt")
    }

    @Test("readTurns concatenation re-indexes turns sequentially")
    func readTurnsConcatenationReindexes() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path1 = (dir as NSString).appendingPathComponent("session1.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Turn A"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Turn B"}]}}"#,
        ].joined(separator: "\n").write(toFile: path1, atomically: true, encoding: .utf8)

        let path2 = (dir as NSString).appendingPathComponent("session2.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Turn C"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path2, atomically: true, encoding: .utf8)

        // Simulate loadFullHistory pattern: read all, re-index
        var allTurns: [ConversationTurn] = []
        for path in [path1, path2] {
            if let turns = try? await TranscriptReader.readTurns(from: path) {
                allTurns.append(contentsOf: turns)
            }
        }
        let reindexed = allTurns.enumerated().map { idx, turn in
            ConversationTurn(
                index: idx,
                lineNumber: turn.lineNumber,
                role: turn.role,
                textPreview: turn.textPreview,
                timestamp: turn.timestamp,
                contentBlocks: turn.contentBlocks
            )
        }

        #expect(reindexed.count == 3)
        // Indices should be sequential across files
        #expect(reindexed[0].index == 0)
        #expect(reindexed[1].index == 1)
        #expect(reindexed[2].index == 2)
        // Content preserved
        #expect(reindexed[0].textPreview == "Turn A")
        #expect(reindexed[2].textPreview == "Turn C")
    }

    @Test("Empty previous session paths produces same result as single file")
    func emptyPreviousPathsMatchesSingleFile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("session.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Only prompt"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Only reply"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        // No previous paths — just the current session
        let paths: [String] = [path]
        var allTurns: [ConversationTurn] = []
        for p in paths {
            for await turn in TranscriptReader.streamAllTurns(from: p) {
                allTurns.append(turn)
            }
        }

        let userPrompts = allTurns.filter { $0.role == "user" }
        #expect(userPrompts.count == 1)
        #expect(userPrompts[0].textPreview == "Only prompt")
    }
}
