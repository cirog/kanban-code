import Foundation

/// A configured project (repository) that Kanban tracks.
public struct Project: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String // Project directory (where Claude runs)
    public var name: String // Display name
    public var repoRoot: String? // Git repo root if different from path
    public var visible: Bool

    public init(path: String, name: String? = nil, repoRoot: String? = nil, visible: Bool = true) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.repoRoot = repoRoot
        self.visible = visible
    }

    /// The effective git repository root (repoRoot if set, otherwise path).
    public var effectiveRepoRoot: String {
        repoRoot ?? path
    }
}
