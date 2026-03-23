import Foundation

/// Parses Claude Code .jsonl files line-by-line using streaming.
/// Handles arbitrarily large lines (57KB+).
public enum JsonlParser {

    /// Metadata extracted from a session .jsonl file.
    public struct SessionMetadata: Sendable {
        public let sessionId: String
        public var firstPrompt: String?
        public var projectPath: String?
        public var gitBranch: String?
        public var slug: String?
        public var messageCount: Int

        public init(
            sessionId: String,
            firstPrompt: String? = nil,
            projectPath: String? = nil,
            gitBranch: String? = nil,
            slug: String? = nil,
            messageCount: Int = 0
        ) {
            self.sessionId = sessionId
            self.firstPrompt = firstPrompt
            self.projectPath = projectPath
            self.gitBranch = gitBranch
            self.slug = slug
            self.messageCount = messageCount
        }
    }

    /// Extract session metadata by streaming through the .jsonl file.
    /// Stops early once the first user message is found (for efficiency).
    public static func extractMetadata(from filePath: String) async throws -> SessionMetadata? {
        let sessionId = (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")

        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        let url = URL(fileURLWithPath: filePath)
        var metadata = SessionMetadata(sessionId: sessionId)
        var foundFirstUserMessage = false

        // Stream line-by-line using FileHandle + AsyncBytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        for try await line in handle.bytes.lines {
            guard !line.isEmpty else { continue }

            // Quick pre-filter before JSON parsing
            guard line.contains("\"type\"") else { continue }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard let type = obj["type"] as? String else { continue }

            // Extract project path from cwd
            if metadata.projectPath == nil, let cwd = obj["cwd"] as? String {
                metadata.projectPath = cwd
            }

            // Extract git branch
            if metadata.gitBranch == nil, let branch = obj["gitBranch"] as? String {
                metadata.gitBranch = branch
            }

            // Extract conversation slug (continuity identifier across context resets)
            if metadata.slug == nil, let slug = obj["slug"] as? String {
                metadata.slug = slug
            }

            if type == "user" || type == "assistant" {
                metadata.messageCount += 1
            }

            // Extract first user message (skip metadata injected by Claude Code)
            if type == "user" && !foundFirstUserMessage {
                if isMetadataMessage(obj) { continue }
                foundFirstUserMessage = true
                if let text = extractTextContent(from: obj) {
                    metadata.firstPrompt = stripMetadataTags(text)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Stop early — we only need first prompt + enough messages to confirm non-empty
            if metadata.messageCount >= 5 && foundFirstUserMessage {
                break
            }
        }

        guard metadata.messageCount > 0 else { return nil }
        return metadata
    }

    /// Extract text content from a message object.
    static func extractTextContent(from obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] else {
            return nil
        }

        // Content can be a string or an array of content blocks
        if let text = content as? String {
            return text
        }

        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    // MARK: - Metadata message detection

    /// Known metadata XML tag names injected by Claude Code.
    private static let metadataTagNames = [
        "local-command-caveat",
        "command-name",
        "command-message",
        "command-args",
        "local-command-stdout",
        "task-notification",
    ]

    /// Regex matching any known metadata XML tag pair (greedy within each pair).
    private nonisolated(unsafe) static let metadataTagRegex: Regex<(Substring, Substring)> = {
        let tagPattern = metadataTagNames.joined(separator: "|")
        return try! Regex("<(\(tagPattern))>[\\s\\S]*?</\\1>")
    }()

    /// True if this user message is purely internal metadata (skip for prompt extraction).
    /// Matches `isMeta: true` messages and messages whose content is entirely metadata tags.
    public static func isMetadataMessage(_ obj: [String: Any]) -> Bool {
        if obj["isMeta"] as? Bool == true { return true }
        guard let text = extractTextContent(from: obj), !text.isEmpty else { return false }
        let stripped = stripMetadataTags(text)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True only for `isMeta: true` messages (the `<local-command-caveat>` wrapper).
    /// These are hidden entirely from the History tab.
    public static func isCaveatMessage(_ obj: [String: Any]) -> Bool {
        obj["isMeta"] as? Bool == true
    }

    /// True if this user message contains `<local-command-stdout>` output.
    /// These should be displayed as assistant-style responses.
    public static func isLocalCommandStdout(_ obj: [String: Any]) -> Bool {
        guard let text = extractTextContent(from: obj) else { return false }
        return text.contains("<local-command-stdout>")
    }

    /// True if this user message is a background task notification.
    /// These should be displayed as assistant-style responses (like stdout).
    public static func isTaskNotification(_ obj: [String: Any]) -> Bool {
        guard let text = extractTextContent(from: obj) else { return false }
        return text.hasPrefix("<task-notification>")
    }

    /// Extract command name from `<command-name>/foo</command-name>` → `/foo`.
    public static func parseLocalCommand(_ text: String) -> String? {
        let regex = try! Regex("<command-name>([\\s\\S]*?)</command-name>")
        guard let match = text.firstMatch(of: regex) else { return nil }
        let command = String(match.output[1].substring!)
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract args from `<command-args>text</command-args>`.
    public static func parseLocalCommandArgs(_ text: String) -> String? {
        let regex = try! Regex("<command-args>([\\s\\S]*?)</command-args>")
        guard let match = text.firstMatch(of: regex) else { return nil }
        let args = String(match.output[1].substring!)
        return args.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract output text from `<local-command-stdout>text</local-command-stdout>`.
    public static func parseLocalCommandStdout(_ text: String) -> String? {
        let regex = try! Regex("<local-command-stdout>([\\s\\S]*?)</local-command-stdout>")
        guard let match = text.firstMatch(of: regex) else { return nil }
        let output = String(match.output[1].substring!)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove all known metadata XML tag pairs, returning the remaining text.
    public static func stripMetadataTags(_ text: String) -> String {
        text.replacing(metadataTagRegex, with: "")
    }

    /// System-generated user message prefixes that are not real user input.
    private static let systemMessagePrefixes = [
        "<task-notification>",
        "<command-message>",
        "<command-name>",
        "<local-command-",
    ]

    /// True if this user turn contains actual user-typed text.
    /// Returns false for tool_result-only turns, task-notifications, slash commands, and skill loading.
    public static func isRealUserMessage(_ obj: [String: Any]) -> Bool {
        guard let message = obj["message"] as? [String: Any] else { return false }

        // String content — check for system-generated patterns
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in systemMessagePrefixes {
                if trimmed.hasPrefix(prefix) { return false }
            }
            return true
        }

        // Array content — must have a text block that isn't skill loading
        if let content = message["content"] as? [[String: Any]] {
            return content.contains { block in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return false }
                if text.hasPrefix("Base directory for this skill:") { return false }
                return true
            }
        }

        return false
    }

    /// Derive the project path from a session file's absolute path.
    /// e.g., "~/.claude/projects/-Users-ciro/abc.jsonl" → "/Users/ciro"
    /// Returns nil if the path can't be decoded to a meaningful directory.
    public static func projectPathFromSessionPath(_ sessionPath: String) -> String? {
        let dir = (sessionPath as NSString).deletingLastPathComponent
        let dirName = (dir as NSString).lastPathComponent
        guard dirName.hasPrefix("-") else { return nil }
        let decoded = decodeDirectoryName(dirName)
        return decoded.isEmpty || decoded == "/" ? nil : decoded
    }

    /// Decode a Claude projects directory name to a filesystem path.
    /// e.g., "-Users-rchaves-Projects-remote-langwatch" → "/Users/rchaves/Projects/remote/langwatch"
    public static func decodeDirectoryName(_ name: String) -> String {
        // Replace leading dash with /, then remaining dashes that are path separators
        // The pattern is: dashes are used as path separators
        var result = name
        if result.hasPrefix("-") {
            result = "/" + String(result.dropFirst())
        }
        // Replace dashes that are path separators (between path components)
        // Heuristic: a dash followed by an uppercase letter is a path separator
        // Actually, Claude uses dashes for ALL path separators
        result = result.replacingOccurrences(of: "-", with: "/")
        return result
    }
}
