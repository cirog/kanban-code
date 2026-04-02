import Testing
import Foundation
@testable import ClaudeBoardCore

struct AutoCleanupTests {
    @Test func removesAllOldDoneCards() {
        let oldDiscovered = Link(
            column: .done,
            lastActivity: Date.now.addingTimeInterval(-49 * 3600), // >48h
            source: .discovered
        )
        let oldManual = Link(
            column: .done,
            lastActivity: Date.now.addingTimeInterval(-49 * 3600),
            source: .manual
        )
        let oldTodoist = Link(
            column: .done,
            lastActivity: Date.now.addingTimeInterval(-49 * 3600),
            source: .todoist
        )
        let recentDiscovered = Link(
            column: .done,
            lastActivity: Date.now.addingTimeInterval(-12 * 3600),
            source: .discovered
        )

        let result = AutoCleanup.clean(links: [oldDiscovered, oldManual, oldTodoist, recentDiscovered])

        #expect(result.count == 1) // only recentDiscovered survives
        #expect(result[0].id == recentDiscovered.id)
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

    @Test func keepsNonDoneCards_evenIfVeryOld() {
        let backlog = Link(
            column: .backlog,
            updatedAt: Date.now.addingTimeInterval(-30 * 86400), // 30 days ago
            source: .manual
        )
        let inProgress = Link(
            column: .inProgress,
            updatedAt: Date.now.addingTimeInterval(-30 * 86400),
            source: .discovered
        )
        let waiting = Link(
            column: .waiting,
            updatedAt: Date.now.addingTimeInterval(-30 * 86400),
            source: .discovered
        )

        let result = AutoCleanup.clean(links: [backlog, inProgress, waiting])
        #expect(result.count == 3) // none removed — only Done expires
    }
}
