Feature: Coordination File
  As a developer debugging Kanban's session linking
  I want a clear, human-readable coordination file
  So that I can inspect and manually fix links when needed

  Background:
    Given the Kanban application is running

  # ── File Structure ──

  Scenario: Coordination file location and format
    Then the coordination file should be at ~/.kanban/links.json
    And it should be valid JSON, pretty-printed for readability
    And it should be inspectable with `cat ~/.kanban/links.json | jq`

  Scenario: Link entry structure
    Given a session is linked to a worktree, tmux session, and PR
    Then the link entry should look like:
      """json
      {
        "id": "uuid-for-this-link",
        "sessionId": "claude-session-uuid",
        "sessionPath": "/Users/rchaves/.claude/projects/-Users-rchaves-Projects-remote-langwatch/uuid.jsonl",
        "worktreePath": "/Users/rchaves/Projects/remote/langwatch-saas/.claude/worktrees/feat-login",
        "worktreeBranch": "feat/login",
        "tmuxSession": "feat-login",
        "githubIssue": 123,
        "githubPR": 456,
        "projectPath": "/Users/rchaves/Projects/remote/langwatch-saas",
        "column": "in_progress",
        "name": "Implement login flow",
        "createdAt": "2026-02-28T10:00:00.000Z",
        "updatedAt": "2026-02-28T10:30:00.000Z",
        "lastActivity": "2026-02-28T10:30:00.000Z",
        "manualOverrides": {
          "worktreePath": false,
          "tmuxSession": false,
          "name": true
        },
        "manuallyArchived": false,
        "source": "github_issue"
      }
      """

  Scenario: Partial links are valid
    Given a session exists without a worktree or tmux session
    Then the link entry should have null for unlinked fields:
      """json
      {
        "id": "uuid",
        "sessionId": "abc-123",
        "worktreePath": null,
        "worktreeBranch": null,
        "tmuxSession": null,
        "githubIssue": null,
        "githubPR": null,
        "column": "all_sessions",
        "name": "Quick question about APIs",
        "manualOverrides": {},
        "manuallyArchived": false,
        "source": "discovered"
      }
      """

  # ── File Operations ──

  Scenario: Atomic writes
    When the coordination file is updated
    Then it should be written atomically:
      | Step | Action                                    |
      | 1    | Write to ~/.kanban/links.json.tmp         |
      | 2    | Rename links.json.tmp to links.json       |
    And this prevents partial writes on crash

  Scenario: Concurrent access safety
    Given multiple processes might read/write the file
    Then updates should use file locking
    And reads should not require locks (eventual consistency is OK)
    And the lock file should be ~/.kanban/links.json.lock

  Scenario: File corruption recovery
    Given the coordination file is corrupted
    When Kanban tries to read it
    Then it should:
      | Step | Action                                    |
      | 1    | Detect invalid JSON                       |
      | 2    | Back up corrupted file as links.json.bkp  |
      | 3    | Rebuild from session discovery             |
      | 4    | Show notification about the recovery      |

  # ── Link Lifecycle ──

  Scenario: New session creates a link entry
    Given a new Claude session "abc-123" is discovered
    When no link exists for this session
    Then a new link entry should be created with:
      | Field     | Value        |
      | sessionId | abc-123      |
      | column    | all_sessions (or in_progress if hook triggered) |
      | source    | discovered or hook                              |

  Scenario: Link fields are updated incrementally
    Given a link exists with sessionId only
    When the background process discovers a matching worktree
    Then only the worktree-related fields should update
    And other fields should remain unchanged
    And updatedAt should be refreshed

  Scenario: Link cleanup for deleted sessions
    Given a link references a .jsonl file that no longer exists
    When the background process runs
    Then the link should be marked as orphaned
    And after 7 days, orphaned links should be cleaned up

  Scenario: Link cleanup for deleted worktrees
    Given a link references a worktree path that no longer exists
    When the background process detects the missing worktree
    Then the worktreePath and worktreeBranch should be set to null
    And the tmuxSession link should also be cleared (if path-based)

  # ── Manual Editing ──

  Scenario: User edits the file directly
    Given I open ~/.kanban/links.json in a text editor
    When I change a worktreePath to a different path
    And save the file
    Then Kanban should detect the change
    And the UI should update to reflect the new link
    And the manual change should be treated as a manual override

  Scenario: User adds a manual link entry
    Given I add a new JSON entry to the links array
    When Kanban reloads the file
    Then the new entry should appear on the board
    And it should be treated as a manually created link

  # ── Debugging ──

  Scenario: Link file is useful for debugging
    Given I'm debugging why a session isn't linked to its worktree
    When I run `cat ~/.kanban/links.json | jq '.links[] | select(.sessionId == "abc-123")'`
    Then I should see all the link data for that session
    And I should be able to identify what's missing or wrong
    And manually fix it if needed
