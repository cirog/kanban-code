import Testing
import Foundation
@testable import ClaudeBoardCore

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






    @Test("ClaudeBoardColumn display names")
    func columnDisplayNames() {
        #expect(ClaudeBoardColumn.inProgress.displayName == "In Progress")
        #expect(ClaudeBoardColumn.waiting.displayName == "Waiting")
        #expect(ClaudeBoardColumn.done.displayName == "Done")
    }

    @Test("ClaudeBoardColumn allows board task creation only in working lanes")
    func columnBoardTaskCreationEligibility() {
        #expect(ClaudeBoardColumn.backlog.allowsBoardTaskCreation)
        #expect(ClaudeBoardColumn.inProgress.allowsBoardTaskCreation)
        #expect(ClaudeBoardColumn.waiting.allowsBoardTaskCreation)
        #expect(ClaudeBoardColumn.done.allowsBoardTaskCreation)
    }

    // Worktree test removed (worktree feature stripped)

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
