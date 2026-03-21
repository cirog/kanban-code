import Testing
import Foundation
@testable import ClaudeBoardCore

struct AutoCleanupTests {
    @Test func removesOldDoneCards_discoveredOnly() {
        let oldDiscovered = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600),
            source: .discovered
        )
        let oldManual = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600),
            source: .manual
        )
        let oldHook = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600),
            source: .hook
        )
        let recentDiscovered = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-12 * 3600),
            source: .discovered
        )

        let result = AutoCleanup.clean(links: [oldDiscovered, oldManual, oldHook, recentDiscovered])

        #expect(result.count == 3) // only oldDiscovered removed
        #expect(!result.contains(where: { $0.id == oldDiscovered.id }))
        #expect(result.contains(where: { $0.id == oldManual.id }))
        #expect(result.contains(where: { $0.id == oldHook.id }))
        #expect(result.contains(where: { $0.id == recentDiscovered.id }))
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
