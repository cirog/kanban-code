import Foundation

/// Polls Todoist for tasks with the @claude label and syncs them to the board.
public actor TodoistSyncService {
    private var timer: Task<Void, Never>?
    private var dispatch: (@MainActor @Sendable (Action) -> Void)?

    public init() {}

    public func setDispatch(_ dispatch: @MainActor @Sendable @escaping (Action) -> Void) {
        self.dispatch = dispatch
    }

    public func start() {
        timer = Task {
            await fetchAndSync()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await fetchAndSync()
            }
        }
    }

    public func stop() {
        timer?.cancel()
    }

    private func fetchAndSync() async {
        do {
            let todoistPath = ShellCommand.findExecutable("todoist") ?? "todoist"
            let output = try await ShellCommand.run(todoistPath, arguments: ["task", "list", "--label", "claude", "--raw"])
            let tasks = try Self.parseTasks(from: output.stdout)
            ClaudeBoardLog.info("todoist", "Synced \(tasks.count) tasks")
            if let dispatch {
                await dispatch(.todoistSyncCompleted(tasks))
            }
        } catch {
            ClaudeBoardLog.warn("todoist", "Sync failed: \(error)")
        }
    }

    /// Parse JSON output from `todoist task list --format json`.
    public static func parseTasks(from json: String) throws -> [TodoistTask] {
        guard let data = json.data(using: .utf8) else { return [] }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let content = item["content"] as? String else { return nil }
            let description = item["description"] as? String
            let priority = item["priority"] as? Int ?? 1
            let labels = item["labels"] as? [String]
            let projectId = item["project_id"] as? String
            // due is a nested object with a "date" field
            let due: String? = (item["due"] as? [String: Any])?["date"] as? String
            return TodoistTask(
                id: id,
                content: content,
                description: description,
                priority: priority,
                due: due,
                labels: labels,
                projectId: projectId
            )
        }
    }
}
