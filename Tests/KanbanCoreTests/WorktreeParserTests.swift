import Testing
import Foundation
@testable import KanbanCore

@Suite("Git Worktree Parser")
struct WorktreeParserTests {
    let adapter = GitWorktreeAdapter()

    @Test("Parse porcelain output with multiple worktrees")
    func parseMultiple() {
        let output = """
        worktree /Users/test/Projects/myapp
        HEAD abc123
        branch refs/heads/main

        worktree /Users/test/Projects/myapp/.worktrees/feature-x
        HEAD def456
        branch refs/heads/feature-x

        worktree /Users/test/Projects/myapp/.worktrees/fix-bug
        HEAD 789abc
        branch refs/heads/fix/bug-123

        """
        let worktrees = adapter.parseWorktreeList(output)
        #expect(worktrees.count == 3)

        #expect(worktrees[0].path == "/Users/test/Projects/myapp")
        #expect(worktrees[0].branch == "main")
        #expect(!worktrees[0].isBare)

        #expect(worktrees[1].path == "/Users/test/Projects/myapp/.worktrees/feature-x")
        #expect(worktrees[1].branch == "feature-x")

        #expect(worktrees[2].path == "/Users/test/Projects/myapp/.worktrees/fix-bug")
        #expect(worktrees[2].branch == "fix/bug-123")
    }

    @Test("Parse bare worktree")
    func parseBare() {
        let output = """
        worktree /Users/test/Projects/myapp.git
        bare

        """
        let worktrees = adapter.parseWorktreeList(output)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].isBare)
        #expect(worktrees[0].branch == nil)
    }

    @Test("Empty output returns empty")
    func emptyOutput() {
        let worktrees = adapter.parseWorktreeList("")
        #expect(worktrees.isEmpty)
    }

    @Test("Single worktree (main only)")
    func singleWorktree() {
        let output = """
        worktree /Users/test/project
        HEAD abc123
        branch refs/heads/main

        """
        let worktrees = adapter.parseWorktreeList(output)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].branch == "main")
    }

    @Test("Worktree directory name extraction")
    func directoryName() {
        let wt = Worktree(path: "/Users/test/Projects/myapp/.worktrees/feature-x", branch: "feature-x")
        #expect(wt.directoryName == "feature-x")
    }
}
