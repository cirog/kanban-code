import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Domain Entities")
struct EntityTests {
    @Test("Session displayTitle uses name first")
    func sessionDisplayTitle() {
        let session = Session(id: "abc-123", name: "My Session", firstPrompt: "Hello")
        #expect(session.displayTitle == "My Session")
    }

    @Test("Session displayTitle falls back to firstPrompt")
    func sessionDisplayTitleFallback() {
        let session = Session(id: "abc-123", firstPrompt: "Fix the login bug")
        #expect(session.displayTitle == "Fix the login bug")
    }

    @Test("Session displayTitle falls back to ID prefix")
    func sessionDisplayTitleIdFallback() {
        let session = Session(id: "abc-12345-678")
        #expect(session.displayTitle == "abc-1234...")
    }






    @Test("KanbanCodeColumn display names")
    func columnDisplayNames() {
        #expect(KanbanCodeColumn.inProgress.displayName == "In Progress")
        #expect(KanbanCodeColumn.waiting.displayName == "Waiting")
        #expect(KanbanCodeColumn.allSessions.displayName == "All Sessions")
    }

    @Test("KanbanCodeColumn allows board task creation only in working lanes")
    func columnBoardTaskCreationEligibility() {
        #expect(KanbanCodeColumn.backlog.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.inProgress.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.waiting.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.inReview.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.done.allowsBoardTaskCreation)
        #expect(!KanbanCodeColumn.allSessions.allowsBoardTaskCreation)
    }

    @Test("Worktree directoryName extracts last component")
    func worktreeDirectoryName() {
        let wt = Worktree(path: "/Users/rchaves/Projects/repo/.claude/worktrees/feat-login", branch: "feat/login")
        #expect(wt.directoryName == "feat-login")
    }

    @Test("Project effectiveRepoRoot uses repoRoot when set")
    func projectRepoRoot() {
        let p = Project(path: "/a/b/langwatch", repoRoot: "/a/b")
        #expect(p.effectiveRepoRoot == "/a/b")
    }

    @Test("Project effectiveRepoRoot falls back to path")
    func projectRepoRootFallback() {
        let p = Project(path: "/a/b/langwatch")
        #expect(p.effectiveRepoRoot == "/a/b/langwatch")
    }

    // MARK: - TmuxLink

    @Test("TmuxLink defaults to Claude session (not shell-only)")
    func tmuxLinkDefaultNotShellOnly() {
        let tmux = TmuxLink(sessionName: "my-project")
        #expect(tmux.isShellOnly == nil)
        #expect(tmux.sessionName == "my-project")
    }

    @Test("TmuxLink shell-only flag round-trips through JSON")
    func tmuxLinkShellOnlyRoundTrip() throws {
        let tmux = TmuxLink(sessionName: "my-project", isShellOnly: true)
        #expect(tmux.isShellOnly == true)

        let data = try JSONEncoder().encode(tmux)
        let decoded = try JSONDecoder().decode(TmuxLink.self, from: data)
        #expect(decoded.isShellOnly == true)
        #expect(decoded.sessionName == "my-project")
    }

    @Test("TmuxLink backward-compat decodes without isShellOnly")
    func tmuxLinkBackwardCompat() throws {
        let json = #"{"sessionName":"old-session"}"#
        let decoded = try JSONDecoder().decode(TmuxLink.self, from: json.data(using: .utf8)!)
        #expect(decoded.sessionName == "old-session")
        #expect(decoded.isShellOnly == nil)
    }
}
