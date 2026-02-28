Feature: Session Launching
  As a developer using Kanban
  I want to launch Claude Code sessions from the board
  So that I can start work with proper worktree and tmux setup

  Background:
    Given the Kanban application is running
    And tmux is installed

  # ── Launching from Backlog ──

  Scenario: Launch Claude with worktree for a GitHub issue
    Given a GitHub issue "#123: Fix login bug" is in Backlog
    And the project is configured at "~/Projects/remote/langwatch-saas"
    When I click "Start"
    Then the following should happen in order:
      | Step | Action                                                        |
      | 1    | Create tmux session named "issue-123"                         |
      | 2    | Inside tmux: cd to project directory                          |
      | 3    | Run: claude --worktree issue-123                              |
      | 4    | Send prompt with skill prefix + issue description             |
    And the coordination file should record the link

  Scenario: Launch Claude with auto-generated worktree name
    Given a manual task without a specific branch name
    When I click "Start"
    Then Claude should be launched with `claude --worktree`
    And Claude Code will auto-generate the worktree name
    And the background process should later detect the worktree and link it

  Scenario: Launch Claude in a sub-repo
    Given a project is configured with:
      | projectPath | ~/Projects/remote/langwatch-saas/langwatch |
      | repoRoot    | ~/Projects/remote/langwatch-saas           |
    When I start a task
    Then Claude should be launched in the projectPath
    But worktrees and PRs should be tracked against the repoRoot
    And the worktree should be created in the repoRoot

  Scenario: Sub-repo worktree creation
    Given a project with repoRoot different from projectPath
    When a worktree needs to be created
    Then `git -C <repoRoot> worktree add` should be used
    And the tmux session should cd to the worktree path

  # ── Launching without tmux ──

  Scenario: tmux not installed
    Given tmux is not installed
    When I click "Start" on a backlog item
    Then Claude should still be launched
    But in a background process instead of a tmux session
    And the card should show "no tmux" indicator
    And I should see a hint to install tmux for better experience

  # ── Launching with remote execution ──

  Scenario: Remote execution configured
    Given remote execution is configured with:
      | Setting    | Value                         |
      | host       | ubuntu@server.com             |
      | remotePath | /home/ubuntu/Projects         |
      | localPath  | ~/Projects/remote             |
    When I start a task for project "~/Projects/remote/langwatch-saas"
    Then Claude should be launched with the remote shell wrapper
    And the SHELL environment variable should point to the fake shell
    And Mutagen sync should be started for the project

  # ── Resuming ──

  Scenario: Resume an existing session from any column
    Given a session "abc-123" exists in "Requires Attention"
    When I open the terminal and send a message
    Then if there's a tmux session, it should be attached
    And Claude should be resumed with `claude --resume abc-123`
    And it should use `$SHELL -ic` to inherit aliases

  Scenario: Resume without tmux session
    Given a session "abc-123" exists but has no tmux session
    When I click "Resume"
    Then a new tmux session should be created
    And `claude --resume abc-123` should be run inside it
    And the coordination file should record the new tmux link

  Scenario: Copy resume command
    Given a session "abc-123" exists
    When I click "Copy resume command"
    Then `claude --resume abc-123` should be copied to clipboard
    And a toast should show "Copied to clipboard"
