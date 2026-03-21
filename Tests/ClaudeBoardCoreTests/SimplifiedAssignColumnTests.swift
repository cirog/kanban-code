import Testing
import Foundation
@testable import ClaudeBoardCore

struct SimplifiedAssignColumnTests {

    // MARK: - User Intent (always respected)

    @Test func manualOverride_respectedWhenNotActivelyWorking() {
        var link = Link(column: .backlog, source: .manual)
        link.manualOverrides = ManualOverrides(column: true)
        let result = AssignColumn.assign(link: link, isClaudeRunning: true, lastHookEvent: "Stop")
        #expect(result == .backlog) // override wins when Claude is idle
    }

    @Test func manualOverride_piercedByActivelyWorking() {
        var link = Link(column: .backlog, source: .manual)
        link.manualOverrides = ManualOverrides(column: true)
        let result = AssignColumn.assign(link: link, isClaudeRunning: true, lastHookEvent: "UserPromptSubmit")
        #expect(result == .inProgress) // active Claude pierces override
    }

    @Test func archived_goesToDone() {
        var link = Link(source: .discovered)
        link.manuallyArchived = true
        let result = AssignColumn.assign(link: link, isClaudeRunning: true)
        #expect(result == .done)
    }

    // MARK: - Claude Running

    @Test func claudeRunning_userPromptSubmit_inProgress() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, isClaudeRunning: true, lastHookEvent: "UserPromptSubmit")
        #expect(result == .inProgress)
    }

    @Test func claudeRunning_stop_waiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, isClaudeRunning: true, lastHookEvent: "Stop")
        #expect(result == .waiting)
    }

    @Test func claudeRunning_sessionStart_waiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, isClaudeRunning: true, lastHookEvent: "SessionStart")
        #expect(result == .waiting)
    }

    @Test func claudeRunning_noHookEvent_waiting() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, isClaudeRunning: true, lastHookEvent: nil)
        #expect(result == .waiting)
    }

    @Test func claudeRunning_managed_userPromptSubmit_inProgress() {
        let link = Link(source: .manual)
        let result = AssignColumn.assign(link: link, isClaudeRunning: true, lastHookEvent: "UserPromptSubmit")
        #expect(result == .inProgress)
    }

    // MARK: - Claude NOT Running — Discovered → Done

    @Test func notRunning_discovered_done() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, isClaudeRunning: false)
        #expect(result == .done)
    }

    @Test func notRunning_discovered_withOldHookEvent_done() {
        let link = Link(source: .discovered)
        let result = AssignColumn.assign(link: link, isClaudeRunning: false, lastHookEvent: "Stop")
        #expect(result == .done)
    }

    // MARK: - Claude NOT Running — Managed/Todoist → Waiting (sticky)

    @Test func notRunning_managed_waiting() {
        let link = Link(source: .manual, slug: "some-slug")
        let result = AssignColumn.assign(link: link, isClaudeRunning: false, lastHookEvent: "Stop")
        #expect(result == .waiting)
    }

    @Test func notRunning_todoist_waiting() {
        let link = Link(source: .todoist, slug: "some-slug")
        let result = AssignColumn.assign(link: link, isClaudeRunning: false, lastHookEvent: "Stop")
        #expect(result == .waiting)
    }

    // MARK: - Unstarted Tasks → Backlog

    @Test func notRunning_manual_noSession_backlog() {
        let link = Link(source: .manual) // no slug, no hook event = never started
        let result = AssignColumn.assign(link: link, isClaudeRunning: false)
        #expect(result == .backlog)
    }

    @Test func notRunning_todoist_noSession_backlog() {
        let link = Link(source: .todoist)
        let result = AssignColumn.assign(link: link, isClaudeRunning: false)
        #expect(result == .backlog)
    }
}
