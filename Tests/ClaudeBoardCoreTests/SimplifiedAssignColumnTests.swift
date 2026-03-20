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

    @Test func noProcess_default_goesToDone() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .done)
    }

    // MARK: - Removed behaviors: no longer special-cased

    @Test func noProcess_needsAttention_noTmux_goesToDone() {
        // Without a live process, needsAttention alone doesn't keep card in waiting
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .needsAttention, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func noProcess_idleWaiting_noTmux_goesToDone() {
        // Without a live process, idleWaiting alone doesn't keep card in waiting
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .idleWaiting, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func noProcess_recentActivity_goesToDone() {
        // 24h recency heuristic removed — recent lastActivity alone doesn't mean waiting
        var link = Link(source: .discovered)
        link.lastActivity = Date.now.addingTimeInterval(-3600) // 1h ago
        let result = AssignColumn.assign(link: link, activityState: .ended, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func noProcess_scheduledTask_goesToDone() {
        // No special-case for <scheduled-task> — just a dead session
        var link = Link(source: .discovered)
        link.promptBody = "<scheduled-task>daily check</scheduled-task>"
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .done)
    }

    @Test func noProcess_summarySession_goesToDone() {
        // No special-case for [CB-SUMMARY] — just a dead session
        var link = Link(source: .discovered)
        link.promptBody = "[CB-SUMMARY] Weekly recap"
        let result = AssignColumn.assign(link: link, activityState: nil, hasLiveTmux: false)
        #expect(result == .done)
    }
}
