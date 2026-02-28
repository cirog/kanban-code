import Foundation

/// Application settings, stored at ~/.kanban/settings.json.
public struct Settings: Codable, Sendable {
    public var projects: [Project]
    public var globalView: GlobalViewSettings
    public var github: GitHubSettings
    public var notifications: NotificationSettings
    public var remote: RemoteSettings?
    public var sessionTimeout: SessionTimeoutSettings
    public var skill: String
    public var columnOrder: [KanbanColumn]

    public init(
        projects: [Project] = [],
        globalView: GlobalViewSettings = GlobalViewSettings(),
        github: GitHubSettings = GitHubSettings(),
        notifications: NotificationSettings = NotificationSettings(),
        remote: RemoteSettings? = nil,
        sessionTimeout: SessionTimeoutSettings = SessionTimeoutSettings(),
        skill: String = "",
        columnOrder: [KanbanColumn] = KanbanColumn.allCases
    ) {
        self.projects = projects
        self.globalView = globalView
        self.github = github
        self.notifications = notifications
        self.remote = remote
        self.sessionTimeout = sessionTimeout
        self.skill = skill
        self.columnOrder = columnOrder
    }
}

public struct GlobalViewSettings: Codable, Sendable {
    public var excludedPaths: [String]

    public init(excludedPaths: [String] = []) {
        self.excludedPaths = excludedPaths
    }
}

public struct GitHubSettings: Codable, Sendable {
    public var defaultFilter: String
    public var pollIntervalSeconds: Int

    public init(defaultFilter: String = "assignee:@me is:open", pollIntervalSeconds: Int = 60) {
        self.defaultFilter = defaultFilter
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

public struct NotificationSettings: Codable, Sendable {
    public var pushoverToken: String?
    public var pushoverUserKey: String?

    public init(pushoverToken: String? = nil, pushoverUserKey: String? = nil) {
        self.pushoverToken = pushoverToken
        self.pushoverUserKey = pushoverUserKey
    }
}

public struct RemoteSettings: Codable, Sendable {
    public var host: String
    public var remotePath: String
    public var localPath: String

    public init(host: String, remotePath: String, localPath: String) {
        self.host = host
        self.remotePath = remotePath
        self.localPath = localPath
    }
}

public struct SessionTimeoutSettings: Codable, Sendable {
    public var activeThresholdMinutes: Int

    public init(activeThresholdMinutes: Int = 1440) {
        self.activeThresholdMinutes = activeThresholdMinutes
    }
}

/// Reads and writes ~/.kanban/settings.json.
public actor SettingsStore {
    private let filePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban")
        self.filePath = (base as NSString).appendingPathComponent("settings.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    /// Read settings, creating defaults if file doesn't exist.
    public func read() throws -> Settings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            let defaults = Settings()
            try write(defaults)
            return defaults
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return try decoder.decode(Settings.self, from: data)
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
    }

    /// The file path for external access.
    public var path: String { filePath }
}
