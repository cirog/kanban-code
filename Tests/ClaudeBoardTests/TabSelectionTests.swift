import Testing
@testable import ClaudeBoard
import ClaudeBoardCore

@Suite("Tab Selection Priority")
struct TabSelectionTests {

    /// Minimal session for tests that need card.session != nil
    private static let stubSession = Session(id: "stub-session-id")

    // MARK: - initialTab (fallback when no lastTab saved)

    @Test("Fallback: tmux card → terminal")
    func fallbackTmux() {
        let card = ClaudeBoardCard(
            link: Link(id: "1", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       tmuxLink: TmuxLink(sessionName: "s1")),
            session: Self.stubSession
        )
        #expect(DetailTab.initialTab(for: card) == .terminal)
    }

    @Test("Fallback: session card (no tmux) → history")
    func fallbackHistory() {
        let card = ClaudeBoardCard(
            link: Link(id: "2", name: "t", projectPath: "/p", column: .inProgress, source: .discovered),
            session: Self.stubSession
        )
        #expect(DetailTab.initialTab(for: card) == .history)
    }

    @Test("Fallback: bare card (no tmux, no session) → prompt")
    func fallbackPrompt() {
        let card = ClaudeBoardCard(
            link: Link(id: "3", name: "t", projectPath: "/p", column: .backlog, source: .manual)
        )
        #expect(DetailTab.initialTab(for: card) == .prompt)
    }

    // MARK: - defaultTab (saved lastTab restoration)

    @Test("Saved history tab is restored")
    func savedHistory() {
        let card = ClaudeBoardCard(
            link: Link(id: "4", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "history"),
            session: Self.stubSession
        )
        #expect(DetailTab.defaultTab(for: card) == .history)
    }

    @Test("Saved prompt tab is restored")
    func savedPrompt() {
        let card = ClaudeBoardCard(
            link: Link(id: "5", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "prompt"),
            session: Self.stubSession
        )
        #expect(DetailTab.defaultTab(for: card) == .prompt)
    }

    @Test("Saved summary tab is restored")
    func savedSummary() {
        let card = ClaudeBoardCard(
            link: Link(id: "6", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "summary"),
            session: Self.stubSession
        )
        #expect(DetailTab.defaultTab(for: card) == .summary)
    }

    @Test("Saved description tab is restored when todoist present")
    func savedDescriptionWithTodoist() {
        let card = ClaudeBoardCard(
            link: Link(id: "7", name: "t", projectPath: "/p", column: .inProgress, source: .todoist,
                       todoistId: "123", lastTab: "description")
        )
        #expect(DetailTab.defaultTab(for: card) == .description)
    }

    @Test("Saved description tab falls through when todoist removed")
    func savedDescriptionWithoutTodoist() {
        let card = ClaudeBoardCard(
            link: Link(id: "8", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "description"),
            session: Self.stubSession
        )
        #expect(DetailTab.defaultTab(for: card) == .history)
    }

    @Test("Saved terminal tab is restored when tmux present")
    func savedTerminalWithTmux() {
        let card = ClaudeBoardCard(
            link: Link(id: "9", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", tmuxLink: TmuxLink(sessionName: "s1"), lastTab: "terminal"),
            session: Self.stubSession
        )
        #expect(DetailTab.defaultTab(for: card) == .terminal)
    }

    @Test("Saved terminal tab falls through when tmux gone")
    func savedTerminalWithoutTmux() {
        let card = ClaudeBoardCard(
            link: Link(id: "10", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "terminal"),
            session: Self.stubSession
        )
        #expect(DetailTab.defaultTab(for: card) == .history)
    }

    @Test("No saved tab → uses initialTab fallback")
    func noSavedTab() {
        let card = ClaudeBoardCard(
            link: Link(id: "11", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", tmuxLink: TmuxLink(sessionName: "s1")),
            session: Self.stubSession
        )
        #expect(DetailTab.defaultTab(for: card) == .terminal)
    }
}
