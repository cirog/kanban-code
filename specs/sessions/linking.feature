Feature: Session-Worktree-Tmux-PR Linking
  As a developer with sessions started from various places
  I want Kanban to intelligently link sessions, worktrees, tmux sessions, and PRs
  So that my board accurately represents the state of all work

  Background:
    Given the Kanban application is running
    And the background linking process is active

  # ── Coordination File ──

  Scenario: Coordination file structure
    Given the application has been used
    Then a file should exist at ~/.kanban/links.json
    And it should be human-readable JSON with entries like:
      """json
      {
        "links": [
          {
            "id": "link-uuid",
            "sessionId": "claude-session-uuid",
            "worktreePath": "/path/to/worktree",
            "worktreeBranch": "feat/issue-123",
            "tmuxSession": "feat-issue-123",
            "githubIssue": 123,
            "githubPR": 456,
            "projectPath": "/Users/rchaves/Projects/remote/langwatch-saas",
            "column": "in_progress",
            "name": "Custom session name",
            "createdAt": "2026-02-28T10:00:00Z",
            "updatedAt": "2026-02-28T10:30:00Z",
            "manualOverrides": {},
            "manuallyArchived": false
          }
        ]
      }
      """

  Scenario: Coordination file is always readable
    Given the coordination file exists
    Then it should be valid JSON
    And it should be inspectable with `cat ~/.kanban/links.json | jq`
    And it should be editable by the user if needed

  # ── Automatic Linking: Session → Worktree ──

  Scenario: Session started with --worktree flag
    Given Claude was started with `claude --worktree feat-123`
    When the session .jsonl contains cwd pointing to a worktree path
    Then the session should be automatically linked to that worktree
    And the branch should be extracted from the worktree

  Scenario: Session without worktree but mentions branch in conversation
    Given a Claude session is running on main (no --worktree)
    And the conversation contains a message mentioning "worktree feat-login"
    And no other link exists for "feat-login"
    When the background heuristic scanner runs
    Then it should attempt to match the branch name "feat-login"
    And if a worktree exists with that branch, link them

  Scenario: Heuristic matching via exact branch name in conversation
    Given a worktree exists at ~/Projects/remote/langwatch-saas/.claude/worktrees/feat-login
    And a Claude session's transcript mentions "feat-login" exactly
    And the session has no worktree link yet
    Then the heuristic should propose this link
    And the link should be created automatically

  Scenario: No false positive heuristic matches
    Given a Claude session discusses "login" in general terms
    And a worktree "feat-login" exists
    Then the heuristic should NOT link them
    Because "login" alone is not an exact branch/worktree name match

  # ── Automatic Linking: Worktree → tmux ──
  # (Learned from git-orchard: path match first, then name match)

  Scenario: tmux session matches worktree by path
    Given a tmux session exists with session_path = "/path/to/worktree"
    And a worktree exists at "/path/to/worktree"
    Then they should be linked by exact path match (highest priority)

  Scenario: tmux session matches worktree by directory name
    Given a tmux session named "feat-login"
    And a worktree at ~/Projects/remote/repo/.claude/worktrees/feat-login/
    Then they should be linked by directory name match

  Scenario: tmux session matches worktree by branch name
    Given a tmux session named "feat-login"
    And a worktree on branch "feat/login" (slash-to-dash normalization)
    Then they should be linked because "feat/login" → "feat-login" matches

  Scenario: Path match takes priority over name match
    Given tmux session "wrong-name" has path "/correct/worktree"
    And worktree at "/correct/worktree" on branch "correct-branch"
    Then the tmux session should be linked to the worktree
    Because path match (priority 1) overrides name match (priority 2)

  # ── Automatic Linking: Worktree → PR ──
  # (Learned from git-orchard: branch name is the PR map key)

  Scenario: PR linked by branch name
    Given a worktree is on branch "feat/issue-123"
    And a PR exists with head ref "feat/issue-123"
    Then the PR should be automatically linked to the worktree/session

  Scenario: PR fetched via gh CLI
    When the background process checks for PRs
    Then it should use `gh pr list --state all --json headRefName,number,state,title,url,reviewDecision`
    And cache the results as a Map<branchName, PrInfo>

  # ── Automatic Linking: PR → GitHub Issue ──

  Scenario: PR body references an issue
    Given PR #456 has body containing "Closes #123"
    When the PR is linked to a session
    Then the GitHub issue #123 should also be linked
    And if #123 was in the Backlog, the backlog card should be merged with the session card

  # ── Manual Override ──

  Scenario: User manually changes worktree link
    Given a session is linked to worktree "feat-login"
    When I click "Change worktree" on the card
    And select a different worktree "feat-auth"
    Then the link should update to "feat-auth"
    And "manualOverrides.worktreePath" should be set to true
    And the heuristic should not overwrite this manual link

  Scenario: User manually links a tmux session
    Given a session has no tmux link
    When I click "Link tmux session"
    And I see a list of unlinked tmux sessions
    And I select "my-session"
    Then the tmux session should be linked
    And the link should be marked as manual

  Scenario: Manual overrides survive re-linking
    Given a session has a manual worktree override
    When the background linking process runs
    Then it should skip the manually overridden field
    And only update non-overridden fields

  # ── Multiple Sessions per Worktree ──

  Scenario: Two sessions linked to the same worktree
    Given I started a session in worktree "feat-login"
    And I later forked it, creating a second session in the same worktree
    Then both sessions should appear as cards
    And both should show the same worktree link
    And the PR should appear on both cards

  # ── Session Switching Worktrees ──

  Scenario: User switches worktree within a session
    Given session "abc-123" was linked to worktree "feat-login"
    And the user told Claude to switch to worktree "feat-auth"
    When the background process detects cwd changed to a different worktree
    Then the session link should update to "feat-auth"
    Unless there is a manual override

  # ── No Worktree (working on main) ──

  Scenario: Session without a worktree
    Given a Claude session is running in ~/Projects/remote/langwatch-saas (not a worktree)
    Then the session should be tracked without a worktree link
    And the branch should show as "main" (or whatever the current branch is)
    And the card should still be fully functional

  # ── Background Process Performance ──

  Scenario: Linking process is lightweight
    Given 50 active sessions and 200 archived sessions
    When the background linking process runs
    Then it should complete in under 500ms
    And it should not block the UI thread
    And it should only re-scan sessions that changed since last run

  Scenario: tmux session list is cached and refreshed
    Given the linking process polls tmux sessions
    Then `tmux list-sessions` should be called at most every 5 seconds
    And the result should be cached between polls
