import Foundation

// MARK: - Typed Link Sub-Structs

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
    case task = "TASK"
    case todoist = "TODOIST"
}

// MARK: - Link (Card Entity)

/// The coordination record — a card on the board with independently optional typed links.
/// Stored in ~/.kanban-code/links.db (SQLite).
public struct Link: Identifiable, Codable, Sendable {
    public let id: String

    // Card-level properties
    public var name: String?
    public var projectPath: String?
    public var column: ClaudeBoardColumn
    public var createdAt: Date
    public var updatedAt: Date
    public var lastActivity: Date?
    public var lastOpenedAt: Date?
    public var manualOverrides: ManualOverrides
    public var manuallyArchived: Bool
    public var source: LinkSource
    public var promptBody: String?
    public var promptImagePaths: [String]?

    // Todoist integration
    public var todoistId: String?
    public var todoistDescription: String?
    public var todoistPriority: Int?
    public var todoistDue: String?
    public var todoistLabels: [String]?
    public var todoistProjectId: String?
    public var notes: String?
    public var projectId: String?

    // Session association key — links this card to sessions via session_links table
    public var slug: String?

    // Typed links — each independently optional
    public var tmuxLink: TmuxLink?
    public var queuedPrompts: [QueuedPrompt]?

    /// Manual sort order within a column. Cards with sortOrder are sorted by it
    /// (lower first); cards without fall back to time-based sort.
    public var sortOrder: Int?

    /// Which coding assistant this card uses. nil defaults to .claude for backward compat.
    public var assistant: CodingAssistant?

    /// Persisted tab selection — restored when the card is re-selected.
    public var lastTab: String?

    /// The effective assistant (never nil).
    public var effectiveAssistant: CodingAssistant { assistant ?? .claude }

    /// Launch lock — true while an async launch/resume is in progress.
    /// Prevents background reconciliation from overriding card state mid-launch.
    public var isLaunching: Bool?

    // MARK: - Display

    /// Best display title from link data alone: name → promptBody → session ID.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let promptBody, !promptBody.isEmpty { return String(promptBody.prefix(100)) }
        return id
    }

    // MARK: - Backward-compat computed properties

    /// Tmux session name. Use `tmuxLink?.sessionName` for new code.
    public var tmuxSession: String? { tmuxLink?.sessionName }

    /// The primary label for this card based on which links are present.
    public var cardLabel: CardLabel {
        if slug != nil { return .session }
        if todoistId != nil { return .todoist }
        return .task
    }

    // MARK: - Merge Validation

    /// Check if two cards can be merged. Returns nil if allowed, or an error message if not.
    public static func mergeBlocked(source: Link, target: Link) -> String? {
        if source.id == target.id { return "Cannot merge a card with itself" }
        if source.slug != nil && target.slug != nil {
            return "Cannot merge: both cards have sessions"
        }
        if source.tmuxLink != nil && target.tmuxLink != nil {
            return "Cannot merge: both cards have terminals"
        }
        return nil
    }

    // MARK: - Init

    public init(
        id: String = KSUID.generate(prefix: "card"),
        name: String? = nil,
        projectPath: String? = nil,
        column: ClaudeBoardColumn = .done,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastActivity: Date? = nil,
        lastOpenedAt: Date? = nil,
        manualOverrides: ManualOverrides = ManualOverrides(),
        manuallyArchived: Bool = false,
        source: LinkSource = .discovered,
        promptBody: String? = nil,
        promptImagePaths: [String]? = nil,
        todoistId: String? = nil,
        todoistDescription: String? = nil,
        todoistPriority: Int? = nil,
        todoistDue: String? = nil,
        todoistLabels: [String]? = nil,
        todoistProjectId: String? = nil,
        notes: String? = nil,
        projectId: String? = nil,
        slug: String? = nil,
        tmuxLink: TmuxLink? = nil,
        queuedPrompts: [QueuedPrompt]? = nil,
        assistant: CodingAssistant? = nil,
        lastTab: String? = nil,
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
        self.todoistId = todoistId
        self.todoistDescription = todoistDescription
        self.todoistPriority = todoistPriority
        self.todoistDue = todoistDue
        self.todoistLabels = todoistLabels
        self.todoistProjectId = todoistProjectId
        self.notes = notes
        self.projectId = projectId
        self.slug = slug
        self.tmuxLink = tmuxLink
        self.queuedPrompts = queuedPrompts
        self.assistant = assistant
        self.lastTab = lastTab
        self.isLaunching = isLaunching
        self.sortOrder = sortOrder
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        // Card-level
        case id, slug, name, projectPath, column, createdAt, updatedAt, lastActivity, lastOpenedAt
        case manualOverrides, manuallyArchived, source, promptBody, promptImagePaths, isLaunching, sortOrder
        case assistant, lastTab
        // Todoist integration
        case todoistId, todoistDescription, todoistPriority, todoistDue, todoistLabels, todoistProjectId, notes, projectId
        // Typed links
        case tmuxLink, queuedPrompts
        // Old format keys (for reading legacy format)
        case tmuxSession, issueBody
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        column = try c.decodeIfPresent(ClaudeBoardColumn.self, forKey: .column) ?? .done
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        manualOverrides = try c.decodeIfPresent(ManualOverrides.self, forKey: .manualOverrides) ?? ManualOverrides()
        manuallyArchived = try c.decodeIfPresent(Bool.self, forKey: .manuallyArchived) ?? false
        source = try c.decodeIfPresent(LinkSource.self, forKey: .source) ?? .discovered
        promptBody = try c.decodeIfPresent(String.self, forKey: .promptBody)
        promptImagePaths = try c.decodeIfPresent([String].self, forKey: .promptImagePaths)
        isLaunching = try c.decodeIfPresent(Bool.self, forKey: .isLaunching)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        assistant = try c.decodeIfPresent(CodingAssistant.self, forKey: .assistant)
        lastTab = try c.decodeIfPresent(String.self, forKey: .lastTab)
        todoistId = try c.decodeIfPresent(String.self, forKey: .todoistId)
        todoistDescription = try c.decodeIfPresent(String.self, forKey: .todoistDescription)
        todoistPriority = try c.decodeIfPresent(Int.self, forKey: .todoistPriority)
        todoistDue = try c.decodeIfPresent(String.self, forKey: .todoistDue)
        todoistLabels = try c.decodeIfPresent([String].self, forKey: .todoistLabels)
        todoistProjectId = try c.decodeIfPresent(String.self, forKey: .todoistProjectId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)

        // Tmux link
        if let tl = try c.decodeIfPresent(TmuxLink.self, forKey: .tmuxLink) {
            tmuxLink = tl
        } else if let ts = try c.decodeIfPresent(String.self, forKey: .tmuxSession) {
            tmuxLink = TmuxLink(sessionName: ts)
        } else {
            tmuxLink = nil
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
        try c.encodeIfPresent(slug, forKey: .slug)
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
        try c.encodeIfPresent(isLaunching, forKey: .isLaunching)
        try c.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(assistant, forKey: .assistant)
        try c.encodeIfPresent(lastTab, forKey: .lastTab)
        try c.encodeIfPresent(todoistId, forKey: .todoistId)
        try c.encodeIfPresent(todoistDescription, forKey: .todoistDescription)
        try c.encodeIfPresent(todoistPriority, forKey: .todoistPriority)
        try c.encodeIfPresent(todoistDue, forKey: .todoistDue)
        try c.encodeIfPresent(todoistLabels, forKey: .todoistLabels)
        try c.encodeIfPresent(todoistProjectId, forKey: .todoistProjectId)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(projectId, forKey: .projectId)

        try c.encodeIfPresent(tmuxLink, forKey: .tmuxLink)
        try c.encodeIfPresent(queuedPrompts, forKey: .queuedPrompts)
    }
}

/// Tracks which fields have been manually set by the user.
public struct ManualOverrides: Codable, Sendable {
    public var name: Bool
    public var column: Bool

    public init(
        name: Bool = false,
        column: Bool = false
    ) {
        self.name = name
        self.column = column
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(Bool.self, forKey: .name) ?? false
        column = try c.decodeIfPresent(Bool.self, forKey: .column) ?? false
    }
}

/// How a link was created.
public enum LinkSource: String, Codable, Sendable {
    case discovered // Found via session scanning
    case hook // Created via Claude hook event
    case manual // User-created task
    case todoist // Synced from Todoist

    // Resilient decoding: unknown sources default to .discovered
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LinkSource(rawValue: raw) ?? .discovered
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
