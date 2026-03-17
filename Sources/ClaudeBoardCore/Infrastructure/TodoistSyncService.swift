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
            let tasks = try await TodoistAdapter.listTasks(label: "claude")
            ClaudeBoardLog.info("todoist", "Synced \(tasks.count) tasks")
            if let dispatch {
                await dispatch(.todoistSyncCompleted(tasks))
            }
        } catch {
            ClaudeBoardLog.warn("todoist", "Sync failed: \(error)")
        }
    }
}
