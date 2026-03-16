import Testing
import Foundation
@testable import ClaudeBoardCore

struct AutoCleanupTests {
    @Test func removesOldDoneCards() {
        let old = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-25 * 3600), // 25h ago
            source: .discovered
        )

        let recent = Link(
            column: .done,
            updatedAt: Date.now.addingTimeInterval(-12 * 3600), // 12h ago
            source: .discovered
        )

        let waiting = Link(
            column: .waiting,
            updatedAt: Date.now.addingTimeInterval(-72 * 3600), // 3 days ago — never expires
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
