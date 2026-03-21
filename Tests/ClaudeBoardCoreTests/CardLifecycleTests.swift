import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("Card Lifecycle")
struct CardLifecycleTests {

    @Test("Claude running + UserPromptSubmit → inProgress")
    func activeToInProgress() {
        var link = Link(column: .done, slug: "s1")
        UpdateCardColumn.update(link: &link, isClaudeRunning: true, lastHookEvent: "UserPromptSubmit")
        #expect(link.column == .inProgress)
    }

    @Test("Claude running + Stop → waiting")
    func stopToWaiting() {
        var link = Link(column: .inProgress, slug: "s1")
        UpdateCardColumn.update(link: &link, isClaudeRunning: true, lastHookEvent: "Stop")
        #expect(link.column == .waiting)
    }

    @Test("Claude not running + discovered → done")
    func notRunningDiscoveredToDone() {
        var link = Link(column: .inProgress, slug: "s1")
        UpdateCardColumn.update(link: &link, isClaudeRunning: false, lastHookEvent: "Stop")
        #expect(link.column == .done)
    }

    @Test("Claude not running + managed → waiting (sticky)")
    func notRunningManagedToWaiting() {
        var link = Link(column: .inProgress, source: .manual, slug: "s1")
        UpdateCardColumn.update(link: &link, isClaudeRunning: false, lastHookEvent: "Stop")
        #expect(link.column == .waiting)
    }

    @Test("Manual override respected when Claude running but not actively working")
    func manualOverrideWhenRunningIdle() {
        var link = Link(column: .done, slug: "s1")
        link.manualOverrides.column = true
        UpdateCardColumn.update(link: &link, isClaudeRunning: true, lastHookEvent: "Stop")
        #expect(link.column == .done)
    }

    @Test("Actively working pierces manual override")
    func activelyWorkingPiercesOverride() {
        var link = Link(column: .backlog, slug: "s1")
        link.manualOverrides.column = true
        UpdateCardColumn.update(link: &link, isClaudeRunning: true, lastHookEvent: "UserPromptSubmit")
        #expect(link.column == .inProgress)
    }

    @Test("Archived card becomes actively working → clears manuallyArchived")
    func archivedCardRevived() {
        var link = Link(column: .done, manuallyArchived: true, slug: "s1")
        UpdateCardColumn.update(link: &link, isClaudeRunning: true, lastHookEvent: "UserPromptSubmit")
        #expect(link.column == .inProgress)
        #expect(link.manuallyArchived == false)
    }

    @Test("Archived card stays archived when Claude not running")
    func archivedCardStaysArchived() {
        var link = Link(column: .done, manuallyArchived: true, slug: "s1")
        UpdateCardColumn.update(link: &link, isClaudeRunning: false)
        #expect(link.column == .done)
        #expect(link.manuallyArchived == true)
    }

    @Test("Column doesn't change when state results in same column")
    func noUnnecessaryUpdate() {
        var link = Link(column: .inProgress, slug: "s1")
        let originalUpdatedAt = link.updatedAt
        UpdateCardColumn.update(link: &link, isClaudeRunning: true, lastHookEvent: "UserPromptSubmit")
        #expect(link.updatedAt == originalUpdatedAt)
    }
}
