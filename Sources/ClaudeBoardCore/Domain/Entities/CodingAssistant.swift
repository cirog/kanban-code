import Foundation

/// Supported coding assistants that can be managed by Kanban Code.
public enum CodingAssistant: String, Codable, Sendable, CaseIterable {
    case claude

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        }
    }

    public var cliCommand: String {
        switch self {
        case .claude: "claude"
        }
    }

    /// Text shown in the TUI when the assistant is ready for input.
    public var promptCharacter: String {
        switch self {
        case .claude: "❯"
        }
    }

    /// CLI flag to auto-approve all tool calls.
    public var autoApproveFlag: String {
        switch self {
        case .claude: "--dangerously-skip-permissions"
        }
    }

    /// CLI flag to resume a session.
    public var resumeFlag: String { "--resume" }

    /// Name of the config directory under $HOME (e.g. ".claude").
    public var configDirName: String {
        switch self {
        case .claude: ".claude"
        }
    }

    /// Symbol used to mark user turns in conversation history UI.
    public var historyPromptSymbol: String {
        switch self {
        case .claude: "❯"
        }
    }

    /// npm package name for installation.
    public var installCommand: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        }
    }
}
