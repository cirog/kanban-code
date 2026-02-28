import Testing
import Foundation
@testable import KanbanCore

@Suite("Domain Entities")
struct EntityTests {
    @Test("Session displayTitle uses name first")
    func sessionDisplayTitle() {
        let session = Session(id: "abc-123", name: "My Session", firstPrompt: "Hello")
        #expect(session.displayTitle == "My Session")
    }

    @Test("Session displayTitle falls back to firstPrompt")
    func sessionDisplayTitleFallback() {
        let session = Session(id: "abc-123", firstPrompt: "Fix the login bug")
        #expect(session.displayTitle == "Fix the login bug")
    }

    @Test("Session displayTitle falls back to ID prefix")
    func sessionDisplayTitleIdFallback() {
        let session = Session(id: "abc-12345-678")
        #expect(session.displayTitle == "abc-1234...")
    }

    @Test("PullRequest status derivation — failing CI")
    func prStatusFailing() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "open", url: "", headRefName: "feat",
            checksStatus: .fail
        )
        #expect(pr.status == .failing)
    }

    @Test("PullRequest status derivation — unresolved threads")
    func prStatusUnresolved() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "open", url: "", headRefName: "feat",
            checksStatus: .pass, unresolvedThreads: 3
        )
        #expect(pr.status == .unresolved)
    }

    @Test("PullRequest status derivation — approved")
    func prStatusApproved() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "open", url: "", headRefName: "feat",
            reviewDecision: "APPROVED", checksStatus: .pass
        )
        #expect(pr.status == .approved)
    }

    @Test("PullRequest status derivation — merged")
    func prStatusMerged() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "merged", url: "", headRefName: "feat"
        )
        #expect(pr.status == .merged)
    }

    @Test("PRStatus ordering — failing has highest urgency")
    func prStatusOrdering() {
        #expect(PRStatus.failing < PRStatus.unresolved)
        #expect(PRStatus.unresolved < PRStatus.changesRequested)
        #expect(PRStatus.changesRequested < PRStatus.reviewNeeded)
        #expect(PRStatus.reviewNeeded < PRStatus.approved)
        #expect(PRStatus.approved < PRStatus.merged)
    }

    @Test("KanbanColumn display names")
    func columnDisplayNames() {
        #expect(KanbanColumn.inProgress.displayName == "In Progress")
        #expect(KanbanColumn.requiresAttention.displayName == "Requires Attention")
        #expect(KanbanColumn.allSessions.displayName == "All Sessions")
    }

    @Test("Worktree directoryName extracts last component")
    func worktreeDirectoryName() {
        let wt = Worktree(path: "/Users/rchaves/Projects/repo/.claude/worktrees/feat-login", branch: "feat/login")
        #expect(wt.directoryName == "feat-login")
    }

    @Test("Project effectiveRepoRoot uses repoRoot when set")
    func projectRepoRoot() {
        let p = Project(path: "/a/b/langwatch", repoRoot: "/a/b")
        #expect(p.effectiveRepoRoot == "/a/b")
    }

    @Test("Project effectiveRepoRoot falls back to path")
    func projectRepoRootFallback() {
        let p = Project(path: "/a/b/langwatch")
        #expect(p.effectiveRepoRoot == "/a/b/langwatch")
    }
}
