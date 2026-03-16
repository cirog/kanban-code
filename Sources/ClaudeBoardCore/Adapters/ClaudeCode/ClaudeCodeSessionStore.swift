import Foundation

/// Implements SessionStore for Claude Code .jsonl files.
public final class ClaudeCodeSessionStore: SessionStore, @unchecked Sendable {

    public init() {}

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        try await TranscriptReader.readTurns(from: sessionPath)
    }

    public func forkSession(sessionPath: String, targetDirectory: String? = nil) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let newSessionId = UUID().uuidString.lowercased()
        let dir = targetDirectory ?? (sessionPath as NSString).deletingLastPathComponent
        if let targetDirectory, !fileManager.fileExists(atPath: targetDirectory) {
            try fileManager.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
        }
        let newPath = (dir as NSString).appendingPathComponent("\(newSessionId).jsonl")

        // Read, replace session IDs, write
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let oldSessionId = (sessionPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")

        var lines: [String] = []
        for try await line in handle.bytes.lines {
            let replaced = line.replacingOccurrences(
                of: "\"\(oldSessionId)\"",
                with: "\"\(newSessionId)\""
            )
            lines.append(replaced)
        }

        try lines.joined(separator: "\n").write(
            toFile: newPath, atomically: true, encoding: .utf8
        )

        // Preserve the original file's mtime so the activity detector
        // doesn't treat the fork as "actively working" (10-second window).
        if let attrs = try? fileManager.attributesOfItem(atPath: sessionPath),
           let originalMtime = attrs[.modificationDate] as? Date {
            try? fileManager.setAttributes(
                [.modificationDate: originalMtime],
                ofItemAtPath: newPath
            )
        }

        return newSessionId
    }

    public func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let encodedPath: String
        if let projectPath {
            encodedPath = SessionFileMover.encodeProjectPath(projectPath)
        } else {
            encodedPath = "-unknown"
        }
        let dir = (base as NSString).appendingPathComponent(encodedPath)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let filePath = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")

        var lines: [String] = []
        let isoFormatter = ISO8601DateFormatter()
        var lastUuid = ""

        for turn in turns {
            let uuid = UUID().uuidString.lowercased()
            let timestamp = turn.timestamp ?? isoFormatter.string(from: .now)
            let type = turn.role == "assistant" ? "assistant" : "user"

            var jsonObj: [String: Any] = [
                "type": type,
                "sessionId": sessionId,
                "uuid": uuid,
                "timestamp": timestamp,
                "isSidechain": false,
                "userType": "external"
            ]
            if !lastUuid.isEmpty {
                jsonObj["parentUuid"] = lastUuid
            }
            if let projectPath {
                jsonObj["cwd"] = projectPath
            }

            if turn.role == "assistant" {
                var contentBlocks: [[String: Any]] = []
                // Collect tool calls so we can emit tool_result lines after
                var toolCalls: [(id: String, name: String, resultText: String)] = []

                for block in turn.contentBlocks {
                    switch block.kind {
                    case .text:
                        contentBlocks.append(["type": "text", "text": block.text])
                    case .toolUse(let name, let input):
                        let toolId = "toolu_migrated_\(UUID().uuidString.prefix(8))"
                        let claudeName = Self.mapToolName(name)
                        let toolBlock: [String: Any] = [
                            "type": "tool_use",
                            "id": toolId,
                            "name": claudeName,
                            "input": input as [String: Any]
                        ]
                        contentBlocks.append(toolBlock)
                        // Extract result from the block text (after " -> ")
                        let resultText: String
                        if let arrowRange = block.text.range(of: " -> ") {
                            resultText = String(block.text[arrowRange.upperBound...])
                        } else {
                            resultText = "(migrated from another assistant)"
                        }
                        toolCalls.append((id: toolId, name: claudeName, resultText: resultText))
                    case .thinking:
                        break
                    case .toolResult(let toolName):
                        // If there's an explicit tool result block, attach it to the last tool call
                        if !toolCalls.isEmpty {
                            toolCalls[toolCalls.count - 1] = (
                                id: toolCalls.last!.id,
                                name: toolCalls.last!.name,
                                resultText: block.text
                            )
                        } else {
                            // Orphan tool result — render as text
                            let label = toolName ?? "tool"
                            contentBlocks.append(["type": "text", "text": "[\(label) result] \(block.text)"])
                        }
                    }
                }
                if contentBlocks.isEmpty {
                    contentBlocks.append(["type": "text", "text": turn.textPreview])
                }

                let hasToolUse = !toolCalls.isEmpty
                let msgId = "msg_migrated_\(UUID().uuidString.prefix(12))"
                var message: [String: Any] = [
                    "id": msgId,
                    "type": "message",
                    "role": "assistant",
                    "content": contentBlocks,
                    "stop_reason": hasToolUse ? "tool_use" : "end_turn",
                    "stop_sequence": NSNull()
                ]
                jsonObj["message"] = message

                if let data = try? JSONSerialization.data(withJSONObject: jsonObj),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
                lastUuid = uuid

                // Emit tool_result lines (Claude expects a separate user message per tool_use)
                for tc in toolCalls {
                    let resultUuid = UUID().uuidString.lowercased()
                    var resultObj: [String: Any] = [
                        "type": "user",
                        "sessionId": sessionId,
                        "uuid": resultUuid,
                        "parentUuid": lastUuid,
                        "timestamp": timestamp,
                        "isSidechain": false,
                        "userType": "external",
                        "sourceToolAssistantUUID": uuid,
                        "message": [
                            "role": "user",
                            "content": [[
                                "type": "tool_result",
                                "tool_use_id": tc.id,
                                "content": tc.resultText,
                                "is_error": false
                            ] as [String: Any]]
                        ] as [String: Any]
                    ]
                    if let projectPath {
                        resultObj["cwd"] = projectPath
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: resultObj),
                       let line = String(data: data, encoding: .utf8) {
                        lines.append(line)
                    }
                    lastUuid = resultUuid
                }
            } else {
                // User or system message
                let textParts = turn.contentBlocks.compactMap { block -> String? in
                    if case .text = block.kind { return block.text }
                    // Render non-text blocks as text for user messages
                    if case .toolUse(let name, let input) = block.kind {
                        let args = input.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                        return "[\(name)(\(args))] \(block.text)"
                    }
                    return nil
                }
                let text = textParts.isEmpty ? turn.textPreview : textParts.joined(separator: "\n")
                let prefix = turn.role == "system" ? "[system] " : ""
                jsonObj["message"] = ["role": "user", "content": prefix + text] as [String: Any]

                if let data = try? JSONSerialization.data(withJSONObject: jsonObj),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
                lastUuid = uuid
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    /// Map tool names from other assistants to Claude Code equivalents.
    private static func mapToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "shell", "run_shell_command", "bash": return "Bash"
        case "readfile", "read_file", "read": return "Read"
        case "writefile", "write_file", "write": return "Write"
        case "editfile", "edit_file", "edit": return "Edit"
        case "glob", "listfiles", "list_files": return "Glob"
        case "grep", "search", "searchfiles": return "Grep"
        default: return name // Keep unknown names as-is, rendered as text fallback
        }
    }

    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        // Backup
        let backupPath = sessionPath + ".bkp"
        try? fileManager.removeItem(atPath: backupPath)
        try fileManager.copyItem(atPath: sessionPath, toPath: backupPath)

        // Read lines up to the target line number
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var keptLines: [String] = []
        var lineNumber = 0

        for try await line in handle.bytes.lines {
            lineNumber += 1
            keptLines.append(line)
            if lineNumber >= afterTurn.lineNumber {
                break
            }
        }

        try keptLines.joined(separator: "\n").write(
            toFile: sessionPath, atomically: true, encoding: .utf8
        )
    }

}

public enum SessionStoreError: Error, LocalizedError {
    case fileNotFound(String)
    case writeNotSupported

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): "Session file not found: \(path)"
        case .writeNotSupported: "This session store does not support writing sessions"
        }
    }
}
