import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("ClaudeBoardCard")
struct ClaudeBoardCardTests {

    @Test("Display title uses link name first")
    func displayTitleLinkName() {
        let link = Link(name: "Fix login bug", slug: "s1")
        let card = ClaudeBoardCard(link: link)
        #expect(card.displayTitle == "Fix login bug")
    }

    @Test("Display title falls back to session")
    func displayTitleSession() {
        let link = Link(slug: "s1")
        let session = Session(id: "s1", firstPrompt: "Help me debug the auth flow")
        let card = ClaudeBoardCard(link: link, session: session)
        #expect(card.displayTitle == "Help me debug the auth flow")
    }

    @Test("Display title falls back to card id")
    func displayTitleFallback() {
        let link = Link(id: "card_test123", slug: "s1")
        let card = ClaudeBoardCard(link: link)
        #expect(card.displayTitle == "card_test123")
    }

    @Test("Relative time formats correctly")
    func relativeTime() {
        #expect(ClaudeBoardCard.formatRelativeTime(Date.now) == "just now")
        #expect(ClaudeBoardCard.formatRelativeTime(Date.now.addingTimeInterval(-120)) == "2m ago")
        #expect(ClaudeBoardCard.formatRelativeTime(Date.now.addingTimeInterval(-7200)) == "2h ago")
        #expect(ClaudeBoardCard.formatRelativeTime(Date.now.addingTimeInterval(-86400)) == "yesterday")
        #expect(ClaudeBoardCard.formatRelativeTime(Date.now.addingTimeInterval(-259200)) == "3d ago")
    }

    @Test("Column comes from link")
    func column() {
        let link = Link(column: .waiting, slug: "s1")
        let card = ClaudeBoardCard(link: link)
        #expect(card.column == .waiting)
    }
}
