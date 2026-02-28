import Foundation

/// A discovered Claude Code session, extracted from .jsonl files and/or session indexes.
public struct Session: Identifiable, Sendable {
    public let id: String // sessionId (UUID string)
    public var name: String? // Custom name or auto-generated summary
    public var firstPrompt: String? // First user message text
    public var projectPath: String? // Decoded project directory path
    public var gitBranch: String? // Git branch if in a worktree
    public var messageCount: Int
    public var modifiedTime: Date
    public var jsonlPath: String? // Full path to the .jsonl file

    public init(
        id: String,
        name: String? = nil,
        firstPrompt: String? = nil,
        projectPath: String? = nil,
        gitBranch: String? = nil,
        messageCount: Int = 0,
        modifiedTime: Date = .now,
        jsonlPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.firstPrompt = firstPrompt
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.messageCount = messageCount
        self.modifiedTime = modifiedTime
        self.jsonlPath = jsonlPath
    }

    /// Display title: custom name → summary → first prompt → session ID prefix.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let firstPrompt, !firstPrompt.isEmpty {
            return String(firstPrompt.prefix(100))
        }
        return String(id.prefix(8)) + "..."
    }
}
