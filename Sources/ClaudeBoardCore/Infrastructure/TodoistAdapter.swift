import Foundation

/// Centralizes all Todoist CLI interactions.
public enum TodoistAdapter {

    /// Fetch tasks with a given label from Todoist.
    public static func listTasks(label: String) async throws -> [TodoistTask] {
        let path = ShellCommand.findExecutable("todoist") ?? "todoist"
        let output = try await ShellCommand.run(path, arguments: ["task", "list", "--label", label, "--raw"])
        return try parseTasks(from: output.stdout)
    }

    /// Mark a task as complete in Todoist.
    public static func completeTask(id: String) async throws {
        let path = ShellCommand.findExecutable("todoist") ?? "todoist"
        let result = try await ShellCommand.run(path, arguments: ["task", "complete", id])
        guard result.succeeded else {
            throw NSError(
                domain: "TodoistAdapter",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "todoist task complete exited with code \(result.exitCode): \(result.stderr)"]
            )
        }
    }

    /// Parse JSON output from `todoist task list --raw`.
    public static func parseTasks(from json: String) throws -> [TodoistTask] {
        guard let data = json.data(using: .utf8) else { return [] }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let content = item["content"] as? String else { return nil }
            return TodoistTask(
                id: id,
                content: content,
                description: item["description"] as? String,
                priority: item["priority"] as? Int ?? 1,
                due: (item["due"] as? [String: Any])?["date"] as? String,
                labels: item["labels"] as? [String],
                projectId: item["project_id"] as? String
            )
        }
    }
}
