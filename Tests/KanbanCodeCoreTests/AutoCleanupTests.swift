import Testing
import Foundation
@testable import KanbanCodeCore

struct AutoCleanupTests {
    @Test func removesOldDoneCards() {
        let old = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-8 * 86400),
            source: .discovered
        )

        let recent = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-86400),
            source: .discovered
        )

        let waiting = Link(
            column: .waiting,
            updatedAt: Date.now.addingTimeInterval(-8 * 86400),
            source: .discovered
        )

        let result = AutoCleanup.clean(links: [old, recent, waiting])

        #expect(result.count == 2) // old Done card removed
        #expect(result.contains(where: { $0.id == recent.id }))
        #expect(result.contains(where: { $0.id == waiting.id }))
    }

    @Test func capsAtMaxCards() {
        var links: [Link] = []
        for i in 0..<1100 {
            let link = Link(
                column: .done,
                updatedAt: Date.now.addingTimeInterval(-Double(i) * 60),
                source: .discovered
            )
            links.append(link)
        }

        let result = AutoCleanup.clean(links: links, maxCards: 1000)
        #expect(result.count == 1000)
    }

    @Test func keepsNonDoneCards_evenIfOld() {
        let old = Link(
            column: .backlog,
            updatedAt: Date.now.addingTimeInterval(-30 * 86400),
            source: .manual
        )

        let result = AutoCleanup.clean(links: [old])
        #expect(result.count == 1)
    }
}
