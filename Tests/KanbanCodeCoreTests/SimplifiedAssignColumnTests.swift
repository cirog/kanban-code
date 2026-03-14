import Testing
import Foundation
@testable import KanbanCodeCore

struct SimplifiedAssignColumnTests {
    @Test func activelyWorking_goesToInProgress() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(result == .inProgress)
    }

    @Test func needsAttention_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .needsAttention)
        #expect(result == .waiting)
    }

    @Test func idleWaiting_goesToWaiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(result == .waiting)
    }

    @Test func ended_recent_goesToWaiting() {
        var link = Link(source: .discovered)
        link.lastActivity = Date.now.addingTimeInterval(-3600) // 1h ago
        let result = AssignColumn.assign(link: link, activityState: .ended)
        #expect(result == .waiting)
    }

    @Test func ended_old_goesToDone() {
        var link = Link(source: .discovered)
        link.lastActivity = Date.now.addingTimeInterval(-90000) // 25h ago
        let result = AssignColumn.assign(link: link, activityState: .ended)
        #expect(result == .done)
    }

    @Test func stale_goesToDone() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, activityState: .stale)
        #expect(result == .done)
    }

    @Test func manualBacklog_isSticky() {
        var link = Link(column: .backlog, source: .manual)
        link.manualOverrides = ManualOverrides(column: true)
        let result = AssignColumn.assign(link: link, activityState: .needsAttention)
        #expect(result == .backlog)
    }

    @Test func manualTask_noSession_goesToBacklog() {
        let link = Link(source: .manual)
        let result = AssignColumn.assign(link: link)
        #expect(result == .backlog)
    }

    @Test func noActivity_default_goesToDone() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link)
        #expect(result == .done)
    }
}
