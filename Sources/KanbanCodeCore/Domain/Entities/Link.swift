import Foundation

// MARK: - Typed Link Sub-Structs

/// Link to a Claude Code session.
public struct SessionLink: Codable, Sendable, Equatable {
    public var sessionId: String
    public var sessionPath: String?
    public var sessionNumber: Int?

    public init(sessionId: String, sessionPath: String? = nil, sessionNumber: Int? = nil) {
        self.sessionId = sessionId
        self.sessionPath = sessionPath
        self.sessionNumber = sessionNumber
    }
}

/// Link to a tmux terminal session.
public struct TmuxLink: Codable, Sendable, Equatable {
    public var sessionName: String          // Primary tmux session
    public var extraSessions: [String]?     // User-created shell terminals
    public var tabNames: [String: String]?  // Custom display names for terminal tabs (sessionName → label)
    public var isShellOnly: Bool?           // true if primary session is a plain shell (not Claude)
    public var isPrimaryDead: Bool?         // true when primary killed but extras survive

    /// All session names (primary + extras).
    public var allSessionNames: [String] {
        var result = [sessionName]
        if let extra = extraSessions { result.append(contentsOf: extra) }
        return result
    }

    /// Total count of terminals.
    public var terminalCount: Int { allSessionNames.count }

    public init(sessionName: String, extraSessions: [String]? = nil, isShellOnly: Bool = false, isPrimaryDead: Bool = false) {
        self.sessionName = sessionName
        self.extraSessions = extraSessions
        self.isShellOnly = isShellOnly ? true : nil // nil when false for compact JSON
        self.isPrimaryDead = isPrimaryDead ? true : nil // nil when false for compact JSON
    }
}

/// Link to a git worktree.
public struct WorktreeLink: Codable, Sendable, Equatable {
    public var path: String
    public var branch: String?

    public init(path: String, branch: String? = nil) {
        self.path = path
        self.branch = branch
    }
}

/// A prompt queued to be sent to a Claude session.
public struct QueuedPrompt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var body: String
    public var sendAutomatically: Bool
    public var imagePaths: [String]?

    public init(id: String = KSUID.generate(prefix: "prompt"), body: String, sendAutomatically: Bool = true, imagePaths: [String]? = nil) {
        self.id = id
        self.body = body
        self.sendAutomatically = sendAutomatically
        self.imagePaths = imagePaths
    }
}

// MARK: - Card Label

/// The primary label shown on a card, derived from which links are present.
public enum CardLabel: String, Sendable {
    case session = "SESSION"
    case worktree = "WORKTREE"
    case task = "TASK"
}

// MARK: - Link (Card Entity)

/// The coordination record — a card on the board with independently optional typed links.
/// Stored in ~/.kanban-code/links.json.
public struct Link: Identifiable, Codable, Sendable {
    public let id: String

    // Card-level properties
    public var name: String?
    public var projectPath: String?
    public var column: KanbanCodeColumn
    public var createdAt: Date
    public var updatedAt: Date
    public var lastActivity: Date?
    public var lastOpenedAt: Date?
    public var manualOverrides: ManualOverrides
    public var manuallyArchived: Bool
    public var source: LinkSource
    public var promptBody: String?
    public var promptImagePaths: [String]?

    // Typed links — each independently optional
    public var sessionLink: SessionLink?
    public var tmuxLink: TmuxLink?
    public var worktreeLink: WorktreeLink?
    public var queuedPrompts: [QueuedPrompt]?

    /// Whether this card's project is configured for remote execution.
    public var isRemote: Bool

    /// Manual sort order within a column. Cards with sortOrder are sorted by it
    /// (lower first); cards without fall back to time-based sort.
    public var sortOrder: Int?

    /// Which coding assistant this card uses. nil defaults to .claude for backward compat.
    public var assistant: CodingAssistant?

    /// The effective assistant (never nil).
    public var effectiveAssistant: CodingAssistant { assistant ?? .claude }

    /// Launch lock — true while an async launch/resume is in progress.
    /// Prevents background reconciliation from overriding card state mid-launch.
    public var isLaunching: Bool?

    // MARK: - Display

    /// Best display title from link data alone: name → promptBody → branch → session ID.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let promptBody, !promptBody.isEmpty { return String(promptBody.prefix(100)) }
        if let branch = worktreeLink?.branch, !branch.isEmpty { return branch }
        if let sid = sessionLink?.sessionId { return sid }
        return id
    }

    // MARK: - Backward-compat computed properties

    /// Claude session UUID. Use `sessionLink?.sessionId` for new code.
    public var sessionId: String? { sessionLink?.sessionId }
    /// Path to .jsonl transcript. Use `sessionLink?.sessionPath` for new code.
    public var sessionPath: String? { sessionLink?.sessionPath }
    /// Tmux session name. Use `tmuxLink?.sessionName` for new code.
    public var tmuxSession: String? { tmuxLink?.sessionName }
    /// Worktree directory path. Use `worktreeLink?.path` for new code.
    public var worktreePath: String? { worktreeLink?.path }
    /// Git branch name. Use `worktreeLink?.branch` for new code.
    public var worktreeBranch: String? { worktreeLink?.branch }
    /// Session display number. Use `sessionLink?.sessionNumber` for new code.
    public var sessionNumber: Int? { sessionLink?.sessionNumber }

    /// The primary label for this card based on which links are present.
    public var cardLabel: CardLabel {
        if sessionLink != nil { return .session }
        if worktreeLink != nil { return .worktree }
        return .task
    }

    // MARK: - Merge Validation

    /// Check if two cards can be merged. Returns nil if allowed, or an error message if not.
    public static func mergeBlocked(source: Link, target: Link) -> String? {
        if source.id == target.id { return "Cannot merge a card with itself" }
        if source.sessionLink != nil && target.sessionLink != nil {
            return "Cannot merge: both cards have sessions"
        }
        if source.tmuxLink != nil && target.tmuxLink != nil {
            return "Cannot merge: both cards have terminals"
        }
        if source.worktreeLink != nil && target.worktreeLink != nil
            && source.worktreeLink != target.worktreeLink {
            return "Cannot merge: both cards have different worktrees"
        }
        return nil
    }

    // MARK: - Init

    public init(
        id: String = KSUID.generate(prefix: "card"),
        name: String? = nil,
        projectPath: String? = nil,
        column: KanbanCodeColumn = .allSessions,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastActivity: Date? = nil,
        lastOpenedAt: Date? = nil,
        manualOverrides: ManualOverrides = ManualOverrides(),
        manuallyArchived: Bool = false,
        source: LinkSource = .discovered,
        promptBody: String? = nil,
        promptImagePaths: [String]? = nil,
        sessionLink: SessionLink? = nil,
        tmuxLink: TmuxLink? = nil,
        worktreeLink: WorktreeLink? = nil,
        queuedPrompts: [QueuedPrompt]? = nil,
        assistant: CodingAssistant? = nil,
        isRemote: Bool = false,
        isLaunching: Bool? = nil,
        sortOrder: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.column = column
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivity = lastActivity
        self.lastOpenedAt = lastOpenedAt
        self.manualOverrides = manualOverrides
        self.manuallyArchived = manuallyArchived
        self.source = source
        self.promptBody = promptBody
        self.promptImagePaths = promptImagePaths
        self.sessionLink = sessionLink
        self.tmuxLink = tmuxLink
        self.worktreeLink = worktreeLink
        self.queuedPrompts = queuedPrompts
        self.assistant = assistant
        self.isRemote = isRemote
        self.isLaunching = isLaunching
        self.sortOrder = sortOrder
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        // Card-level
        case id, name, projectPath, column, createdAt, updatedAt, lastActivity, lastOpenedAt
        case manualOverrides, manuallyArchived, source, promptBody, promptImagePaths, isRemote, isLaunching, sortOrder
        case assistant
        // Typed links (new nested format)
        case sessionLink, tmuxLink, worktreeLink, queuedPrompts
        // Old format keys (for reading legacy format)
        case sessionId, sessionPath, worktreePath, worktreeBranch
        case tmuxSession, sessionNumber, issueBody
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        column = try c.decodeIfPresent(KanbanCodeColumn.self, forKey: .column) ?? .allSessions
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        manualOverrides = try c.decodeIfPresent(ManualOverrides.self, forKey: .manualOverrides) ?? ManualOverrides()
        manuallyArchived = try c.decodeIfPresent(Bool.self, forKey: .manuallyArchived) ?? false
        source = try c.decodeIfPresent(LinkSource.self, forKey: .source) ?? .discovered
        promptBody = try c.decodeIfPresent(String.self, forKey: .promptBody)
        promptImagePaths = try c.decodeIfPresent([String].self, forKey: .promptImagePaths)
        isRemote = try c.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        isLaunching = try c.decodeIfPresent(Bool.self, forKey: .isLaunching)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        assistant = try c.decodeIfPresent(CodingAssistant.self, forKey: .assistant)

        // Session link: try nested first, fallback to flat
        if let sl = try c.decodeIfPresent(SessionLink.self, forKey: .sessionLink) {
            sessionLink = sl
        } else {
            let sid = try c.decodeIfPresent(String.self, forKey: .sessionId)
            let sp = try c.decodeIfPresent(String.self, forKey: .sessionPath)
            let sn = try c.decodeIfPresent(Int.self, forKey: .sessionNumber)
            sessionLink = sid.map { SessionLink(sessionId: $0, sessionPath: sp, sessionNumber: sn) }
        }

        // Tmux link
        if let tl = try c.decodeIfPresent(TmuxLink.self, forKey: .tmuxLink) {
            tmuxLink = tl
        } else if let ts = try c.decodeIfPresent(String.self, forKey: .tmuxSession) {
            tmuxLink = TmuxLink(sessionName: ts)
        } else {
            tmuxLink = nil
        }

        // Worktree link
        if let wl = try c.decodeIfPresent(WorktreeLink.self, forKey: .worktreeLink) {
            worktreeLink = wl
        } else {
            let wp = try c.decodeIfPresent(String.self, forKey: .worktreePath)
            let wb = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
            if let wp {
                worktreeLink = WorktreeLink(path: wp, branch: wb)
            } else if let wb {
                worktreeLink = WorktreeLink(path: "", branch: wb)
            } else {
                worktreeLink = nil
            }
        }

        // Migrate legacy issueBody to promptBody for manual tasks
        if promptBody == nil {
            promptBody = try c.decodeIfPresent(String.self, forKey: .issueBody)
        }

        queuedPrompts = try c.decodeIfPresent([QueuedPrompt].self, forKey: .queuedPrompts)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(projectPath, forKey: .projectPath)
        try c.encode(column, forKey: .column)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastActivity, forKey: .lastActivity)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encode(manualOverrides, forKey: .manualOverrides)
        try c.encode(manuallyArchived, forKey: .manuallyArchived)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(promptBody, forKey: .promptBody)
        try c.encodeIfPresent(promptImagePaths, forKey: .promptImagePaths)
        try c.encode(isRemote, forKey: .isRemote)
        try c.encodeIfPresent(isLaunching, forKey: .isLaunching)
        try c.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(assistant, forKey: .assistant)

        // Always write new nested format
        try c.encodeIfPresent(sessionLink, forKey: .sessionLink)
        try c.encodeIfPresent(tmuxLink, forKey: .tmuxLink)
        try c.encodeIfPresent(worktreeLink, forKey: .worktreeLink)
        try c.encodeIfPresent(queuedPrompts, forKey: .queuedPrompts)
    }
}

/// Tracks which fields have been manually set by the user.
public struct ManualOverrides: Codable, Sendable {
    public var worktreePath: Bool
    public var tmuxSession: Bool
    public var name: Bool
    public var column: Bool

    /// Byte offset into the session JSONL. Data before this point is ignored for branch discovery.
    /// Advances as incremental scanning processes new bytes.
    /// nil = no watermark (default). "Discover Branches" clears it.
    public var branchWatermark: Int?

    /// Whether auto-discovered branch data should be ignored for this card.
    /// True when branchWatermark is set or legacy worktreePath is true.
    public var isBranchDiscoveryBlocked: Bool {
        branchWatermark != nil || worktreePath
    }

    public init(
        worktreePath: Bool = false,
        tmuxSession: Bool = false,
        name: Bool = false,
        column: Bool = false,
        branchWatermark: Int? = nil
    ) {
        self.worktreePath = worktreePath
        self.tmuxSession = tmuxSession
        self.name = name
        self.column = column
        self.branchWatermark = branchWatermark
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        worktreePath = try c.decodeIfPresent(Bool.self, forKey: .worktreePath) ?? false
        tmuxSession = try c.decodeIfPresent(Bool.self, forKey: .tmuxSession) ?? false
        name = try c.decodeIfPresent(Bool.self, forKey: .name) ?? false
        column = try c.decodeIfPresent(Bool.self, forKey: .column) ?? false
        branchWatermark = try c.decodeIfPresent(Int.self, forKey: .branchWatermark)
    }
}

/// How a link was created.
public enum LinkSource: String, Codable, Sendable {
    case discovered // Found via session scanning
    case hook // Created via Claude hook event
    case manual // User-created task
}

/// A single content block within a conversation turn.
public struct ContentBlock: Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        case toolUse(name: String, input: [String: String])
        case toolResult(toolName: String?)
        case thinking
    }

    public let kind: Kind
    public let text: String // rendered text for display

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A conversation turn for history display and checkpoint operations.
public struct ConversationTurn: Sendable {
    public let index: Int
    public let lineNumber: Int
    public let role: String // "user" or "assistant"
    public let textPreview: String
    public let timestamp: String?
    public let contentBlocks: [ContentBlock]

    public init(index: Int, lineNumber: Int, role: String, textPreview: String, timestamp: String? = nil, contentBlocks: [ContentBlock] = []) {
        self.index = index
        self.lineNumber = lineNumber
        self.role = role
        self.textPreview = textPreview
        self.timestamp = timestamp
        self.contentBlocks = contentBlocks
    }
}
