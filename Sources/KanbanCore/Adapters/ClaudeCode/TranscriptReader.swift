import Foundation

/// Reads conversation turns from a .jsonl transcript file.
public enum TranscriptReader {

    /// Read all conversation turns from a .jsonl file.
    public static func readTurns(from filePath: String) async throws -> [ConversationTurn] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }

        let url = URL(fileURLWithPath: filePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var turns: [ConversationTurn] = []
        var lineNumber = 0
        var turnIndex = 0

        for try await line in handle.bytes.lines {
            lineNumber += 1
            guard !line.isEmpty, line.contains("\"type\"") else { continue }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                continue
            }

            guard type == "user" || type == "assistant" else { continue }

            let text: String
            if type == "user" {
                text = JsonlParser.extractTextContent(from: obj) ?? "(empty)"
            } else {
                text = extractAssistantText(from: obj)
            }

            let timestamp = obj["timestamp"] as? String

            turns.append(ConversationTurn(
                index: turnIndex,
                lineNumber: lineNumber,
                role: type,
                textPreview: String(text.prefix(500)),
                timestamp: timestamp
            ))
            turnIndex += 1
        }

        return turns
    }

    /// Extract text from an assistant message (content blocks format).
    static func extractAssistantText(from obj: [String: Any]) -> String {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] else {
            return "(empty)"
        }

        if let text = content as? String {
            return text
        }

        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n")
            return joined.isEmpty ? "(tool use)" : joined
        }

        return "(empty)"
    }
}
