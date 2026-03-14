import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("LaunchSession Multi-Assistant")
struct LaunchSessionMultiAssistantTests {

    // MARK: - Mock

    final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
        var lastCommand: String?
        var lastSessionName: String?
        var killedSessions: [String] = []
        var sessions: [TmuxSession] = []

        func createSession(name: String, path: String, command: String?) async throws {
            lastCommand = command
            lastSessionName = name
        }
        func killSession(name: String) async throws {
            killedSessions.append(name)
        }
        func listSessions() async throws -> [TmuxSession] { sessions }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func capturePane(sessionName: String) async throws -> String { "" }
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
    }

    // MARK: - Launch with Claude

    @Test("Launch with Claude uses 'claude' command")
    func launchClaude() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: true,
            assistant: .claude
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("claude"))
        #expect(cmd.contains("--dangerously-skip-permissions"))
    }

    @Test("Launch with Claude includes worktree flag")
    func launchClaudeWithWorktree() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp/project",
            prompt: "fix bug",
            worktreeName: "feat-login",
            shellOverride: nil,
            skipPermissions: false,
            assistant: .claude
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("--worktree feat-login"))
    }

    // MARK: - Resume

    @Test("Resume with Claude uses claude command and prefix")
    func resumeClaude() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        let sessionName = try await launcher.resume(
            sessionId: "sess_abcdef12-rest",
            projectPath: "/tmp/project",
            shellOverride: nil,
            skipPermissions: true,
            assistant: .claude
        )

        #expect(sessionName == "claude-sess_abc")
        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("claude"))
        #expect(cmd.contains("--resume sess_abcdef12-rest"))
        #expect(cmd.contains("--dangerously-skip-permissions"))
    }

    @Test("Resume without skip permissions omits flag")
    func resumeNoSkipPermissions() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.resume(
            sessionId: "sess_test1234",
            projectPath: "/tmp",
            shellOverride: nil,
            skipPermissions: false,
            assistant: .claude
        )

        let cmd = mock.lastCommand ?? ""
        #expect(!cmd.contains("--dangerously-skip-permissions"))
        #expect(cmd.contains("claude"))
        #expect(cmd.contains("--resume"))
    }

    // MARK: - Shell override

    @Test("Launch with shell override prepends SHELL=")
    func launchWithShellOverride() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp",
            prompt: "test",
            worktreeName: nil,
            shellOverride: "~/.kanban-code/remote/zsh",
            skipPermissions: false,
            assistant: .claude
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("SHELL=~/.kanban-code/remote/zsh"))
        #expect(cmd.contains("claude"))
    }

    // MARK: - Command override

    @Test("Command override is used as-is")
    func commandOverride() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp",
            prompt: "test",
            worktreeName: nil,
            shellOverride: nil,
            commandOverride: "echo 'custom-cmd'",
            skipPermissions: false,
            assistant: .claude
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("echo 'custom-cmd'"))
    }

    // MARK: - Default assistant

    @Test("Launch defaults to Claude when no assistant specified")
    func launchDefaultsClaude() async throws {
        let mock = RecordingTmux()
        let launcher = LaunchSession(tmux: mock)

        _ = try await launcher.launch(
            sessionName: "test",
            projectPath: "/tmp",
            prompt: "test",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: false
        )

        let cmd = mock.lastCommand ?? ""
        #expect(cmd.contains("claude"))
    }
}
