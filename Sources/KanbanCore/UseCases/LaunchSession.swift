import Foundation

/// Launches a new Claude Code session inside a tmux session.
public final class LaunchSession: SessionLauncher, @unchecked Sendable {
    private let tmux: TmuxManagerPort
    private let coordinationStore: CoordinationStore
    private let skillPrefix: String?

    public init(
        tmux: TmuxManagerPort,
        coordinationStore: CoordinationStore,
        skillPrefix: String? = nil
    ) {
        self.tmux = tmux
        self.coordinationStore = coordinationStore
        self.skillPrefix = skillPrefix
    }

    public func launch(
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?
    ) async throws -> String {
        let sessionName = tmuxSessionName(project: projectPath, worktree: worktreeName)

        // Build the claude command
        var cmd = "claude"
        if let worktreeName {
            cmd += " --worktree \(worktreeName)"
        }
        if let shellOverride {
            cmd = "SHELL=\(shellOverride) \(cmd)"
        }

        // Add prompt with optional skill prefix
        let fullPrompt: String
        if let skillPrefix {
            fullPrompt = skillPrefix + " " + prompt
        } else {
            fullPrompt = prompt
        }
        cmd += " -p \(shellEscape(fullPrompt))"

        try await tmux.createSession(name: sessionName, path: projectPath, command: cmd)

        // Record in coordination file
        let link = Link(
            sessionId: sessionName, // will be updated when session ID is discovered
            projectPath: projectPath,
            column: .inProgress,
            source: .manual
        )
        try await coordinationStore.upsertLink(link)

        return sessionName
    }

    public func resume(
        sessionId: String,
        shellOverride: String?
    ) async throws -> String {
        // Check if there's already a tmux session for this
        let existing = try await tmux.listSessions()
        if let match = existing.first(where: { $0.name.contains(String(sessionId.prefix(8))) }) {
            return match.name
        }

        // Create new tmux session with resume command
        let sessionName = "claude-\(String(sessionId.prefix(8)))"
        var cmd = "claude --resume \(sessionId)"
        if let shellOverride {
            cmd = "SHELL=\(shellOverride) \(cmd)"
        }

        // Get project path from coordination file
        let link = try await coordinationStore.linkForSession(sessionId)
        let path = link?.projectPath ?? NSHomeDirectory()

        try await tmux.createSession(name: sessionName, path: path, command: cmd)

        // Update link with tmux session
        try await coordinationStore.updateLink(sessionId: sessionId) { link in
            link.tmuxSession = sessionName
            link.column = .inProgress
        }

        return sessionName
    }

    private func tmuxSessionName(project: String, worktree: String?) -> String {
        let projectName = (project as NSString).lastPathComponent
        if let worktree {
            return "\(projectName)-\(worktree)"
        }
        return projectName
    }

    private func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
