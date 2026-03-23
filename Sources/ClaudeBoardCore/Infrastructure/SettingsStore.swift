import Foundation

/// Application settings, stored at ~/.kanban-code/settings.json.
public struct Settings: Codable, Sendable {
    public var projects: [Project]
    public var globalView: GlobalViewSettings
    public var notifications: NotificationSettings
    public var sessionTimeout: SessionTimeoutSettings
    public var promptTemplate: String
    public var columnOrder: [ClaudeBoardColumn]
    public var hasCompletedOnboarding: Bool
    public var defaultAssistant: CodingAssistant?
    public var enabledAssistants: [CodingAssistant]
    public var projectLabels: [ProjectLabel]

    public init(
        projects: [Project] = [],
        globalView: GlobalViewSettings = GlobalViewSettings(),
        notifications: NotificationSettings = NotificationSettings(),
        sessionTimeout: SessionTimeoutSettings = SessionTimeoutSettings(),
        promptTemplate: String = "",
        columnOrder: [ClaudeBoardColumn] = ClaudeBoardColumn.allCases,
        hasCompletedOnboarding: Bool = false,
        defaultAssistant: CodingAssistant? = nil,
        enabledAssistants: [CodingAssistant] = CodingAssistant.allCases,
        projectLabels: [ProjectLabel] = []
    ) {
        self.projects = projects
        self.globalView = globalView
        self.notifications = notifications
        self.sessionTimeout = sessionTimeout
        self.promptTemplate = promptTemplate
        self.columnOrder = columnOrder
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.defaultAssistant = defaultAssistant
        self.enabledAssistants = enabledAssistants
        self.projectLabels = projectLabels
    }

    private enum CodingKeys: String, CodingKey {
        case projects, globalView, notifications, sessionTimeout
        case promptTemplate, columnOrder, hasCompletedOnboarding, defaultAssistant
        case enabledAssistants, projectLabels
        case skill // backward-compat: old name for promptTemplate
        // Ignored on decode (backward-compat): github, remote, githubIssuePromptTemplate
        case github, remote, githubIssuePromptTemplate
    }

    // Backward-compatible decoding — new fields default gracefully,
    // removed fields (github, remote, githubIssuePromptTemplate) are silently ignored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        globalView = try container.decodeIfPresent(GlobalViewSettings.self, forKey: .globalView) ?? GlobalViewSettings()
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        sessionTimeout = try container.decodeIfPresent(SessionTimeoutSettings.self, forKey: .sessionTimeout) ?? SessionTimeoutSettings()
        // Backward-compat: try "promptTemplate" first, fall back to "skill"
        promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate)
            ?? container.decodeIfPresent(String.self, forKey: .skill) ?? ""
        columnOrder = try container.decodeIfPresent([ClaudeBoardColumn].self, forKey: .columnOrder) ?? ClaudeBoardColumn.allCases
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        defaultAssistant = try container.decodeIfPresent(CodingAssistant.self, forKey: .defaultAssistant)
        enabledAssistants = try container.decodeIfPresent([CodingAssistant].self, forKey: .enabledAssistants)
            ?? CodingAssistant.allCases
        projectLabels = try container.decodeIfPresent([ProjectLabel].self, forKey: .projectLabels) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(globalView, forKey: .globalView)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(sessionTimeout, forKey: .sessionTimeout)
        try container.encode(promptTemplate, forKey: .promptTemplate)
        try container.encode(columnOrder, forKey: .columnOrder)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encodeIfPresent(defaultAssistant, forKey: .defaultAssistant)
        try container.encode(enabledAssistants, forKey: .enabledAssistants)
        try container.encode(projectLabels, forKey: .projectLabels)
        // Note: "skill", "github", "remote", "githubIssuePromptTemplate" are NOT encoded
    }
}

public struct GlobalViewSettings: Codable, Sendable {
    public var excludedPaths: [String]

    public init(excludedPaths: [String] = []) {
        self.excludedPaths = excludedPaths
    }
}

public struct NotificationSettings: Codable, Sendable {
    public var pushoverEnabled: Bool
    public var pushoverToken: String?
    public var pushoverUserKey: String?
    public var renderMarkdownImage: Bool

    public init(pushoverEnabled: Bool = false, pushoverToken: String? = nil, pushoverUserKey: String? = nil, renderMarkdownImage: Bool = false) {
        self.pushoverEnabled = pushoverEnabled
        self.pushoverToken = pushoverToken
        self.pushoverUserKey = pushoverUserKey
        self.renderMarkdownImage = renderMarkdownImage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pushoverEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushoverEnabled) ?? false
        pushoverToken = try c.decodeIfPresent(String.self, forKey: .pushoverToken)
        pushoverUserKey = try c.decodeIfPresent(String.self, forKey: .pushoverUserKey)
        renderMarkdownImage = try c.decodeIfPresent(Bool.self, forKey: .renderMarkdownImage) ?? false
    }
}

public struct SessionTimeoutSettings: Codable, Sendable {
    public var activeThresholdMinutes: Int

    public init(activeThresholdMinutes: Int = 1440) {
        self.activeThresholdMinutes = activeThresholdMinutes
    }
}

/// Reads and writes ~/.kanban-code/settings.json.
/// Caches settings in memory and only re-reads from disk when mtime changes.
public actor SettingsStore {
    private let filePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedSettings: Settings?
    private var cachedMtime: Date?

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("settings.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    /// Read settings, creating defaults if file doesn't exist.
    /// Returns cached value if the file hasn't changed since last read.
    public func read() throws -> Settings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            let defaults = Settings()
            try write(defaults)
            return defaults
        }

        // Check mtime — return cached if unchanged
        let attrs = try? fileManager.attributesOfItem(atPath: filePath)
        let mtime = attrs?[.modificationDate] as? Date
        if let cached = cachedSettings, let cachedMtime, mtime == cachedMtime {
            return cached
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let settings = try decoder.decode(Settings.self, from: data)
        cachedSettings = settings
        cachedMtime = mtime
        return settings
    }

    /// Write settings atomically.
    public func write(_ settings: Settings) throws {
        let fileManager = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try encoder.encode(settings)
        let tmpPath = filePath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        _ = try? fileManager.removeItem(atPath: filePath)
        try fileManager.moveItem(atPath: tmpPath, toPath: filePath)

        // Update cache with the just-written value
        cachedSettings = settings
        cachedMtime = (try? fileManager.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date
    }

    /// The file path for external access.
    public var path: String { filePath }

    // MARK: - Project convenience methods

    /// Add a project to settings. Throws if path already exists.
    public func addProject(_ project: Project) throws {
        var settings = try read()
        guard !settings.projects.contains(where: { $0.path == project.path }) else {
            throw SettingsError.duplicateProject(project.path)
        }
        settings.projects.append(project)
        try write(settings)
    }

    /// Update an existing project (matched by path).
    public func updateProject(_ project: Project) throws {
        var settings = try read()
        guard let index = settings.projects.firstIndex(where: { $0.path == project.path }) else {
            throw SettingsError.projectNotFound(project.path)
        }
        settings.projects[index] = project
        try write(settings)
    }

    /// Remove a project by path.
    public func removeProject(path: String) throws {
        var settings = try read()
        guard settings.projects.contains(where: { $0.path == path }) else {
            throw SettingsError.projectNotFound(path)
        }
        settings.projects.removeAll { $0.path == path }
        try write(settings)
    }

    /// Save the reordered projects list.
    public func reorderProjects(_ projects: [Project]) throws {
        var settings = try read()
        settings.projects = projects
        try write(settings)
    }
}

public enum SettingsError: LocalizedError {
    case duplicateProject(String)
    case projectNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateProject(let path): "Project already configured: \(path)"
        case .projectNotFound(let path): "Project not found: \(path)"
        }
    }
}
