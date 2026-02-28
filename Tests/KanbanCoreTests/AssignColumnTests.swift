import Testing
import Foundation
@testable import KanbanCore

@Suite("AssignColumn")
struct AssignColumnTests {

    @Test("Manual column override is respected")
    func manualOverride() {
        var link = Link(sessionId: "s1", column: .done)
        link.manualOverrides.column = true
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .done)
    }

    @Test("Manually archived goes to allSessions")
    func manuallyArchived() {
        let link = Link(sessionId: "s1", column: .inProgress, manuallyArchived: true)
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .allSessions)
    }

    @Test("PR merged → done")
    func prMerged() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, prMerged: true)
        #expect(col == .done)
    }

    @Test("PR exists + idle → inReview")
    func prExistsIdle() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting, hasPR: true)
        #expect(col == .inReview)
    }

    @Test("PR exists + actively working → inProgress (not inReview)")
    func prExistsActive() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking, hasPR: true)
        #expect(col == .inProgress)
    }

    @Test("Actively working → inProgress")
    func activelyWorking() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .inProgress)
    }

    @Test("Needs attention → requiresAttention")
    func needsAttention() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .needsAttention)
        #expect(col == .requiresAttention)
    }

    @Test("Idle with worktree → inProgress")
    func idleWithWorktree() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting, hasWorktree: true)
        #expect(col == .inProgress)
    }

    @Test("Idle without worktree → allSessions")
    func idleNoWorktree() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(col == .allSessions)
    }

    @Test("Ended with worktree → requiresAttention")
    func endedWithWorktree() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .ended, hasWorktree: true)
        #expect(col == .requiresAttention)
    }

    @Test("Stale → allSessions")
    func stale() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link, activityState: .stale)
        #expect(col == .allSessions)
    }

    @Test("GitHub issue without session → backlog")
    func githubIssueBacklog() {
        let link = Link(sessionId: "s1", source: .githubIssue)
        let col = AssignColumn.assign(link: link)
        #expect(col == .backlog)
    }

    @Test("Manual task without session → backlog")
    func manualTaskBacklog() {
        let link = Link(sessionId: "s1", source: .manual)
        let col = AssignColumn.assign(link: link)
        #expect(col == .backlog)
    }

    @Test("No signals → allSessions")
    func noSignals() {
        let link = Link(sessionId: "s1")
        let col = AssignColumn.assign(link: link)
        #expect(col == .allSessions)
    }
}
