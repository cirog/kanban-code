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

    // MARK: - CardLabel

    @Test("Todoist card gets .todoist label")
    func todoistCardLabel() {
        let link = Link(
            name: "Read article",
            column: .backlog,
            source: .todoist,
            todoistId: "abc123"
        )
        #expect(link.cardLabel == .todoist)
    }

    @Test("Session card still gets .session label even with todoistId")
    func sessionCardLabelOverridesTodoist() {
        let link = Link(
            name: "Session task",
            column: .backlog,
            source: .todoist,
            todoistId: "abc123",
            sessionLink: SessionLink(sessionId: "sess1", sessionPath: nil, sessionNumber: nil)
        )
        #expect(link.cardLabel == .session)
    }

    @Test("Card without todoistId or session gets .task label")
    func plainTaskCardLabel() {
        let link = Link(
            name: "Manual task",
            column: .backlog,
            source: .manual
        )
        #expect(link.cardLabel == .task)
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

    // MARK: - Link lastTab

    @Test("Link round-trips lastTab through JSON")
    func linkLastTabCodable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var link = Link(id: "card_lt1", column: .inProgress)
        link.lastTab = "reply"

        let data = try encoder.encode(link)
        let decoded = try decoder.decode(Link.self, from: data)
        #expect(decoded.lastTab == "reply")
    }

    @Test("Link decodes without lastTab (backward compat)")
    func linkLastTabBackwardCompat() throws {
        let json = #"{"id":"card_lt2","column":"in_progress","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","manualOverrides":{},"manuallyArchived":false,"source":"manual"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Link.self, from: json.data(using: .utf8)!)
        #expect(decoded.lastTab == nil)
    }
}
