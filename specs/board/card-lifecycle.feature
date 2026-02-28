Feature: Card Lifecycle and Automation
  As a developer using Kanban to manage Claude Code sessions
  I want cards to automatically move between columns based on session state
  So that my board always reflects the true state of work

  Background:
    Given the Kanban application is running
    And the background linking process is active

  # ── Backlog → In Progress ──

  Scenario: Starting a task from backlog via Kanban
    Given a task "Implement user auth" is in the Backlog column
    When I click the "Start" button on the card
    Then a tmux session should be created
    And Claude Code should be launched inside it with the task description
    And the card should move to "In Progress"
    And the coordination file should record the session-tmux link

  Scenario: Starting a GitHub issue from backlog
    Given a GitHub issue "#123: Fix login bug" is in the Backlog
    When I click "Start" on the card
    Then a tmux session should be created with name derived from the issue
    And Claude Code should be launched with `claude --worktree issue-123`
    And the prompt should include the issue title and body
    And a configurable skill prefix should be prepended (e.g., "/orchestrate")

  Scenario: Starting a manual task from backlog
    Given a manual task "Refactor database layer" is in the Backlog
    When I click "Start"
    Then a tmux session should be created
    And Claude Code should be launched with `claude --worktree`
    And the worktree should get an auto-generated name (random words)
    And the task description should be the prompt

  Scenario: Task started externally appears in In Progress
    Given I started Claude Code from my terminal with `claude --worktree feat-123`
    When the background process detects the new session
    Then a new card should appear in "In Progress"
    And it should attempt to link to any matching backlog item by branch name

  # ── In Progress → Requires Attention ──

  Scenario: Claude asks for plan approval
    Given a Claude session is actively working in "In Progress"
    When Claude enters plan mode and waits for user input
    Then the card should move to "Requires Attention"
    And a push notification should be sent
    And the card should show "Waiting for plan approval" status

  Scenario: Claude thinks it's done
    Given a Claude session is actively working in "In Progress"
    When Claude's Stop hook fires and no new prompt follows within 1 second
    Then the card should move to "Requires Attention"
    And a push notification should be sent
    And the card should show "Task may be complete" status

  Scenario: Claude needs permission for a tool
    Given a Claude session is actively working
    When Claude triggers a Notification hook for permission request
    Then the card should move to "Requires Attention"
    And the notification should include the permission being requested

  Scenario: Anti-duplicate notifications
    Given a Claude session just triggered a Stop hook
    And a notification was sent
    When a Notification hook fires within 62 seconds for the same session
    Then no duplicate notification should be sent
    And the card should remain in "Requires Attention"

  # ── Requires Attention → In Progress ──

  Scenario: User responds to Claude from Kanban terminal
    Given a card is in "Requires Attention"
    When I open the card's terminal and send a message to Claude
    Then the card should move back to "In Progress"
    And the session activity timestamp should update

  Scenario: User responds from external terminal
    Given a card is in "Requires Attention"
    When I send a message to Claude from my own terminal
    And the UserPromptSubmit hook fires
    Then the card should move back to "In Progress"

  # ── In Progress → In Review ──

  Scenario: PR created while Claude is not actively working
    Given a Claude session created a PR on GitHub
    And the session has been idle for more than 5 minutes
    When the background process detects the PR via `gh`
    Then the card should move to "In Review"
    And the PR number, title, and status should appear on the card

  Scenario: PR exists but Claude is still working
    Given a Claude session has a linked PR
    But the session is actively working (recent activity)
    Then the card should remain in "In Progress"
    And the PR badge should be visible on the card

  # ── In Review → In Progress (addressing feedback) ──

  Scenario: User asks Claude to address review comments
    Given a card is in "In Review" for PR #42
    When I open the terminal and ask Claude to address review feedback
    Then the card should move to "In Progress"
    And when Claude finishes, it should skip "Requires Attention"
    And move directly to "In Review"
    And a notification should still be sent when Claude stops

  # ── In Review → Done ──

  Scenario: PR is merged
    Given a card is in "In Review" for PR #42
    When the PR is merged on GitHub
    And the background process detects the merge via `gh`
    Then the card should move to "Done"
    And the card should show a "Clean up worktree" button

  Scenario: PR is closed without merge
    Given a card is in "In Review" for PR #42
    When the PR is closed without merging
    Then the card should move to "Done"
    And the card should show "Closed" status

  # ── Done → All Sessions (cleanup) ──

  Scenario: Cleaning up a worktree from Done
    Given a card is in "Done" with a linked worktree
    When I click "Clean up worktree"
    Then a confirmation dialog should appear
    And on confirm:
      | Step | Action                                    |
      | 1    | Kill associated tmux session if exists     |
      | 2    | Remove the git worktree                   |
      | 3    | Update coordination file                  |
    And the card should move to "All Sessions"

  Scenario: Done card without worktree moves to archive directly
    Given a card is in "Done" without a linked worktree
    When I click "Archive"
    Then the card should move to "All Sessions"

  # ── All Sessions → In Progress (reviving) ──

  Scenario: Resuming a session from All Sessions
    Given a card is in "All Sessions"
    When I send a message to it via the terminal
    Then the card should move to "In Progress"
    And a tmux session should be created if none exists
    And Claude should be resumed with `claude --resume <sessionId>`

  Scenario: Forking a session from All Sessions
    Given a card is in "All Sessions"
    When I click "Fork"
    Then the session .jsonl should be duplicated with a new UUID
    And a new card should appear in "In Progress" (or "Backlog" if not started)
    And the original card should remain in "All Sessions"

  # ── Session Staleness ──

  Scenario: Active session without worktree or tmux
    Given a session is less than 24 hours old (configurable)
    And it has no linked worktree or tmux session
    Then it should remain in its current column
    And not be auto-archived

  Scenario: Stale session auto-archives
    Given a session has been idle for more than 24 hours (configurable)
    And it has no linked worktree or tmux session
    And it is not in "Backlog"
    Then it should automatically move to "All Sessions"

  Scenario: Manually archiving an active session
    Given a session is in "In Progress"
    When I drag it to "All Sessions"
    Then the card should move to "All Sessions"
    And the session should be marked as manually archived
    And it should not auto-return to "In Progress" based on age alone
