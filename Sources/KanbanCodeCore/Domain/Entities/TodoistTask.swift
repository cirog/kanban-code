import Foundation

/// A task fetched from Todoist's API.
public struct TodoistTask: Sendable {
    public let id: String
    public let content: String
    public let description: String?

    public init(id: String, content: String, description: String? = nil) {
        self.id = id
        self.content = content
        self.description = description
    }
}
