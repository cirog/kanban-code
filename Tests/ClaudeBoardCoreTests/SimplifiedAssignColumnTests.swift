import Testing
import Foundation
@testable import ClaudeBoardCore

struct SimplifiedAssignColumnTests {

    // MARK: - Priority 1: Live Process (always on board)

    @Test func activelyWorking_goesToInProgress() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .activelyWorking, hasLiveTmux: false)
        #expect(result == .inProgress)
    }

    @Test func activelyWorking_piercesManualBacklog() {
        var link = Link(column: .backlog, source: .manual)
        link.manualOverrides = ManualOverrides(column: true)
        let result = AssignColumn.assign(link: link, activityState: .activelyWorking, hasLiveTmux: true)
        #expect(result == .inProgress)
    }

    @Test func activelyWorking_piercesArchived() {
        var link = Link(source: .discovered)
        link.manuallyArchived = true
        let result = AssignColumn.assign(link: link, activityState: .activelyWorking, hasLiveTmux: true)
        #expect(result == .inProgress)
    }

    @Test func liveTmux_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: true)
        #expect(result == .waiting)
    }

    @Test func liveTmux_piercesArchived() {
        var link = Link(source: .discovered)
        link.manuallyArchived = true
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: true)
        #expect(result == .waiting)
    }

    @Test func liveTmux_piercesManualOverride() {
        var link = Link(column: .done, source: .discovered)
        link.manualOverrides = ManualOverrides(column: true)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: true)
        #expect(result == .waiting)
    }

    @Test func liveTmux_withNeedsAttention_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .needsAttention, hasLiveTmux: true)
        #expect(result == .waiting)
    }

    @Test func liveTmux_withIdleWaiting_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .idleWaiting, hasLiveTmux: true)
        #expect(result == .waiting)
    }

    @Test func liveTmux_withEndedActivity_goesToWaiting() {
        // Process is still in tmux even if activity says ended
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .ended, hasLiveTmux: true)
        #expect(result == .waiting)
    }

    // MARK: - Priority 2: No Live Process — User Intent

    @Test func noProcess_manualOverride_respected() {
        var link = Link(column: .backlog, source: .manual)
        link.manualOverrides = ManualOverrides(column: true)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .backlog)
    }

    @Test func noProcess_manualWaiting_respected() {
        var link = Link(column: .waiting, source: .discovered)
        link.manualOverrides = ManualOverrides(column: true)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func noProcess_archived_goesToDone() {
        var link = Link(source: .discovered)
        link.manuallyArchived = true
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .done)
    }

    // MARK: - Priority 3: No Live Process — Classification

    @Test func noProcess_manualTask_noSession_goesToBacklog() {
        let link = Link(source: .manual)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .backlog)
    }

    @Test func noProcess_todoistTask_noSession_goesToBacklog() {
        let link = Link(source: .todoist)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .backlog)
    }

    // MARK: - Priority 4: Activity-Driven (any known state → waiting)

    @Test func noProcess_needsAttention_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .needsAttention, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func noProcess_idleWaiting_discoveredGoesToDone() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .idleWaiting, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func noProcess_idleWaiting_managedGoesToWaiting() {
        let link = Link(source: .manual)
        let result = AssignColumn.assign(link: link, activityState: .idleWaiting, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func noProcess_ended_discoveredGoesToDone() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .ended, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func noProcess_ended_managedGoesToWaiting() {
        let link = Link(source: .manual)
        let result = AssignColumn.assign(link: link, activityState: .ended, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func noProcess_stale_discoveredGoesToDone() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .stale, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func noProcess_stale_managedGoesToWaiting() {
        let link = Link(source: .manual)
        let result = AssignColumn.assign(link: link, activityState: .stale, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    // MARK: - Priority 5: No Data (nil) — Preserve Column

    @Test func nilActivity_noTmux_preservesWaiting() {
        let link = Link(column: .waiting, source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .waiting)
    }

    @Test func nilActivity_noTmux_preservesInProgress() {
        let link = Link(column: .inProgress, source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .inProgress)
    }

    @Test func nilActivity_noTmux_preservesDone() {
        let link = Link(column: .done, source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func nilActivity_noTmux_preservesBacklog() {
        let link = Link(column: .backlog, source: .manual)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .backlog)
    }
}
