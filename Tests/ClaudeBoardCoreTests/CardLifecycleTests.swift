import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("Card Lifecycle")
struct CardLifecycleTests {

    @Test("Active session moves to inProgress")
    func activeToInProgress() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking)
        #expect(link.column == .inProgress)
    }

    @Test("Stop with no follow-up moves to waiting")
    func stopToRequiresAttention() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .needsAttention)
        #expect(link.column == .waiting)
    }

    @Test("Actively working overrides manual column to inProgress")
    func activelyWorkingOverridesManual() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking)
        #expect(link.column == .inProgress)
    }

    @Test("Manual override respected when not actively working")
    func manualOverrideWhenIdle() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        UpdateCardColumn.update(link: &link, activityState: .idleWaiting)
        #expect(link.column == .done)
    }

    @Test("Stale session → done")
    func staleToDone() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .stale)
        #expect(link.column == .done)
    }

    @Test("Archived card becomes actively working → clears manuallyArchived and moves to inProgress")
    func archivedCardRevived() {
        var link = Link(column: .done, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking)
        #expect(link.column == .inProgress)
        #expect(link.manuallyArchived == false)
    }

    @Test("Archived card stays archived when idle")
    func archivedCardStaysArchived() {
        var link = Link(column: .done, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .idleWaiting)
        #expect(link.column == .done)
        #expect(link.manuallyArchived == true)
    }

    @Test("Revived archived card goes to waiting when work stops")
    func revivedCardGoesToWaiting() {
        var link = Link(column: .done, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        // First: actively working clears archive
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking)
        #expect(link.column == .inProgress)
        #expect(link.manuallyArchived == false)
        // Then: work stops → goes to waiting (not back to done)
        UpdateCardColumn.update(link: &link, activityState: .needsAttention)
        #expect(link.column == .waiting)
    }

    @Test("Column doesn't change when state results in same column")
    func noUnnecessaryUpdate() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        let originalUpdatedAt = link.updatedAt
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking)
        // Column is already inProgress, so updatedAt should not change
        #expect(link.updatedAt == originalUpdatedAt)
    }
}
