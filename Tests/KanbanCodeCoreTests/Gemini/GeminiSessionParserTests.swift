import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("GeminiSessionParser")
struct GeminiSessionParserTests {

    // MARK: - Sample Data

    private func writeTempFile(_ content: String) throws -> String {
        let path = "/tmp/kanban-test-gemini-\(UUID().uuidString).json"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private let minimalSession = """
    {
        "sessionId": "abc-123-def",
        "messages": [
            {
                "type": "user",
                "content": [{"text": "Hello, fix the login bug"}]
            },
            {
                "type": "gemini",
                "content": "I'll help you fix the login bug."
            }
        ]
    }
    """

    private let sessionWithToolCalls = """
    {
        "sessionId": "tool-session-1",
        "projectHash": "proj-hash",
        "startTime": "2025-01-15T10:00:00Z",
        "lastUpdated": "2025-01-15T10:05:00Z",
        "summary": "Fixed login validation",
        "messages": [
            {
                "type": "user",
                "content": [{"text": "Fix the login validation"}]
            },
            {
                "type": "gemini",
                "content": "Let me look at the code.",
                "toolCalls": [
                    {
                        "id": "tc1",
                        "name": "readFile",
                        "displayName": "Read File",
                        "args": {"path": "src/login.ts"},
                        "result": "function login() {\\n  // validation here\\n}",
                        "status": "completed"
                    }
                ],
                "thoughts": [
                    {"text": "I need to check the login file first."}
                ]
            },
            {
                "type": "info",
                "content": "File saved successfully"
            },
            {
                "type": "error",
                "content": "Warning: deprecated API"
            }
        ]
    }
    """

    private let sessionWithParts = """
    {
        "sessionId": "parts-session",
        "messages": [
            {
                "type": "user",
                "content": [
                    {"text": "First part"},
                    {"text": "Second part"}
                ]
            },
            {
                "type": "gemini",
                "content": "Got both parts."
            }
        ]
    }
    """

    private let emptyMessagesSession = """
    {
        "sessionId": "empty-session",
        "messages": []
    }
    """

    private let infoOnlySession = """
    {
        "sessionId": "info-only",
        "messages": [
            {
                "type": "info",
                "content": "Session started"
            }
        ]
    }
    """

    // MARK: - Metadata Extraction

    @Test("Extracts metadata from minimal session")
    func extractMinimalMetadata() throws {
        let path = try writeTempFile(minimalSession)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try GeminiSessionParser.extractMetadata(from: path)
        #expect(metadata != nil)
        #expect(metadata?.sessionId == "abc-123-def")
        #expect(metadata?.messageCount == 2)
        #expect(metadata?.firstPrompt == "Hello, fix the login bug")
        #expect(metadata?.summary == nil)
    }

    @Test("Extracts metadata with summary")
    func extractMetadataWithSummary() throws {
        let path = try writeTempFile(sessionWithToolCalls)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try GeminiSessionParser.extractMetadata(from: path)
        #expect(metadata != nil)
        #expect(metadata?.sessionId == "tool-session-1")
        #expect(metadata?.summary == "Fixed login validation")
        #expect(metadata?.firstPrompt == "Fix the login validation")
        // Only user + gemini messages count (not info/error)
        #expect(metadata?.messageCount == 2)
    }

    @Test("Returns nil for empty messages")
    func emptyMessagesReturnsNil() throws {
        let path = try writeTempFile(emptyMessagesSession)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try GeminiSessionParser.extractMetadata(from: path)
        #expect(metadata == nil)
    }

    @Test("Returns nil for info-only session")
    func infoOnlyReturnsNil() throws {
        let path = try writeTempFile(infoOnlySession)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try GeminiSessionParser.extractMetadata(from: path)
        #expect(metadata == nil)
    }

    @Test("Multi-part user content joined")
    func multiPartContent() throws {
        let path = try writeTempFile(sessionWithParts)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try GeminiSessionParser.extractMetadata(from: path)
        #expect(metadata?.firstPrompt == "First part\nSecond part")
    }

    @Test("Long first prompt is truncated to 500 chars")
    func longPromptTruncated() throws {
        let longText = String(repeating: "a", count: 1000)
        let json = """
        {
            "sessionId": "long-prompt",
            "messages": [
                {"type": "user", "content": [{"text": "\(longText)"}]},
                {"type": "gemini", "content": "ok"}
            ]
        }
        """
        let path = try writeTempFile(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try GeminiSessionParser.extractMetadata(from: path)
        #expect(metadata?.firstPrompt?.count == 500)
    }

    // MARK: - Full Parsing

    @Test("Parses full session file")
    func parseFullSession() throws {
        let path = try writeTempFile(minimalSession)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = try GeminiSessionParser.parseSession(from: path)
        #expect(session != nil)
        #expect(session?.sessionId == "abc-123-def")
        #expect(session?.messages.count == 2)
    }

    @Test("Parses session with all fields")
    func parseFullSessionAllFields() throws {
        let path = try writeTempFile(sessionWithToolCalls)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = try GeminiSessionParser.parseSession(from: path)
        #expect(session != nil)
        #expect(session?.projectHash == "proj-hash")
        #expect(session?.startTime == "2025-01-15T10:00:00Z")
        #expect(session?.summary == "Fixed login validation")
        #expect(session?.messages.count == 4)

        let geminiMsg = session?.messages[1]
        #expect(geminiMsg?.toolCalls?.count == 1)
        #expect(geminiMsg?.toolCalls?.first?.name == "readFile")
        #expect(geminiMsg?.toolCalls?.first?.args?["path"] == "src/login.ts")
        #expect(geminiMsg?.thoughts?.first?.text == "I need to check the login file first.")
    }

    // MARK: - MessageContent

    @Test("MessageContent text variant")
    func messageContentText() throws {
        let json = "\"Hello world\""
        let decoded = try JSONDecoder().decode(GeminiSessionParser.MessageContent.self, from: json.data(using: .utf8)!)
        #expect(decoded.textValue == "Hello world")
    }

    @Test("MessageContent parts variant")
    func messageContentParts() throws {
        let json = "[{\"text\": \"part1\"}, {\"text\": \"part2\"}]"
        let decoded = try JSONDecoder().decode(GeminiSessionParser.MessageContent.self, from: json.data(using: .utf8)!)
        #expect(decoded.textValue == "part1\npart2")
    }

    @Test("MessageContent empty fallback")
    func messageContentEmptyFallback() throws {
        let json = "42"
        let decoded = try JSONDecoder().decode(GeminiSessionParser.MessageContent.self, from: json.data(using: .utf8)!)
        #expect(decoded.textValue == "")
    }

    @Test("MessageContent round-trips for text")
    func messageContentTextRoundTrip() throws {
        let original = GeminiSessionParser.MessageContent.text("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeminiSessionParser.MessageContent.self, from: data)
        #expect(decoded.textValue == "hello")
    }

    @Test("MessageContent round-trips for parts")
    func messageContentPartsRoundTrip() throws {
        let original = GeminiSessionParser.MessageContent.parts([
            GeminiSessionParser.ContentPart(text: "a"),
            GeminiSessionParser.ContentPart(text: "b"),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeminiSessionParser.MessageContent.self, from: data)
        #expect(decoded.textValue == "a\nb")
    }

    // MARK: - Error Handling

    @Test("Throws for non-existent file")
    func nonExistentFile() {
        #expect(throws: Error.self) {
            _ = try GeminiSessionParser.extractMetadata(from: "/nonexistent/path/session.json")
        }
    }

    @Test("Throws for invalid JSON")
    func invalidJson() throws {
        let path = try writeTempFile("not json at all")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: Error.self) {
            _ = try GeminiSessionParser.extractMetadata(from: path)
        }
    }
}
