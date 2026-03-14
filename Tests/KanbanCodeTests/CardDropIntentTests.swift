import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Card Drop Intent")
struct CardDropIntentTests {
    @Test("Fresh backlog cards start when dropped into In Progress")
    func backlogCardStarts() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_backlog",
                name: "Fix login bug",
                projectPath: "/test/project",
                column: .backlog,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .inProgress) == .start)
    }

    @Test("Cards can be moved to In Review")
    func cardCanMoveToReview() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_waiting",
                name: "Needs review",
                projectPath: "/test/project",
                column: .waiting,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .inReview) == .move)
    }

    @Test("Cards can be moved to Done")
    func cardCanMoveToDone() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_review",
                name: "Open PR",
                projectPath: "/test/project",
                column: .inReview,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .done) == .move)
    }

    @Test("Archived cards can be restored to Backlog")
    func archivedCardMovesBackToBacklog() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_archived",
                name: "Archived",
                projectPath: "/test/project",
                column: .allSessions,
                manuallyArchived: true,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .backlog) == .move)
    }
}
