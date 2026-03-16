import Foundation

/// A lightweight label for categorizing cards (replaces path-based Project for UI grouping).
public struct ProjectLabel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var color: String  // hex, e.g. "#FF6600"
    public var description: String?

    public init(id: String = KSUID.generate(prefix: "proj"), name: String, color: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.description = description
    }
}
