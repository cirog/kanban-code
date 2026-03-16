import Foundation

/// A task fetched from Todoist's API.
public struct TodoistTask: Sendable {
    public let id: String
    public let content: String
    public let description: String?
    public let priority: Int
    public let due: String?
    public let labels: [String]?
    public let projectId: String?

    public init(
        id: String,
        content: String,
        description: String? = nil,
        priority: Int = 1,
        due: String? = nil,
        labels: [String]? = nil,
        projectId: String? = nil
    ) {
        self.id = id
        self.content = content
        self.description = description
        self.priority = priority
        self.due = due
        self.labels = labels
        self.projectId = projectId
    }
}
