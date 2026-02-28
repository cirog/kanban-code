import Foundation

/// Port for launching and resuming AI CLI sessions.
public protocol SessionLauncher: Sendable {
    /// Launch a new session with a prompt in a project directory.
    func launch(
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?
    ) async throws -> String // returns session ID or tmux session name

    /// Resume an existing session by its ID.
    func resume(
        sessionId: String,
        shellOverride: String?
    ) async throws -> String // returns tmux session name
}
