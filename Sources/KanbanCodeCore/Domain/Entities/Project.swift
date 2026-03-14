import Foundation

/// A configured project (repository) that Kanban tracks.
public struct Project: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String // Project directory (where Claude runs)
    public var name: String // Display name
    public var color: String // Hex color for UI accent (e.g. "#4A90D9")
    public var repoRoot: String? // Git repo root if different from path
    public var visible: Bool

    private enum CodingKeys: String, CodingKey {
        case path, name, color, repoRoot, visible
    }

    public init(
        path: String,
        name: String? = nil,
        color: String = "#808080",
        repoRoot: String? = nil,
        visible: Bool = true
    ) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.color = color
        self.repoRoot = repoRoot
        self.visible = visible
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "#808080"
        visible = try container.decode(Bool.self, forKey: .visible)
        repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot)
    }

    /// The effective git repository root (repoRoot if set, otherwise path).
    public var effectiveRepoRoot: String {
        repoRoot ?? path
    }
}
