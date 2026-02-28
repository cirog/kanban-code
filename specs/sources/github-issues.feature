Feature: GitHub Issues as Backlog Source
  As a developer using GitHub Projects
  I want my assigned issues to appear in the Kanban backlog
  So that I can start working on them with Claude Code directly

  Background:
    Given the Kanban application is running
    And the user has `gh` CLI installed and authenticated
    And the user has configured a GitHub filter

  # ── Configuration ──

  Scenario: Configuring GitHub issue source
    Given I open the settings
    When I set the GitHub filter to "assignee:@me is:open"
    Then the filter should be saved to ~/.kanban/settings.json
    And the backlog should refresh with matching issues

  Scenario: GitHub filter is a raw gh command input
    Given the settings editor shows the GitHub filter field
    Then it should accept raw gh search syntax
    And display a hint: "Uses `gh search issues` syntax"
    And examples like "assignee:@me repo:org/repo is:open label:bug"

  Scenario: Multiple repositories via filter
    Given the filter is "assignee:@me is:open"
    When issues exist across multiple repos
    Then all matching issues should appear in the backlog
    And each card should show the repository name

  Scenario: Filtering by GitHub Project board
    Given the filter is "project:myorg/myproject"
    When the backlog refreshes
    Then only issues from that project board should appear

  # ── Fetching and Display ──

  Scenario: Initial backlog load
    When the Kanban board opens
    Then GitHub issues should be fetched via `gh search issues`
    And each issue should appear as a card in "Backlog" with:
      | Field       | Source              |
      | Title       | Issue title         |
      | Number      | Issue number (#123) |
      | Repository  | repo name           |
      | Labels      | Issue labels        |
      | Assignee    | Assignee avatar     |

  Scenario: Issue already has a linked session
    Given issue #123 is in the backlog
    And a Claude session exists that is working on branch "issue-123"
    When the linking process detects the match
    Then the card should move from "Backlog" to the appropriate column
    And the card should show the linked session

  Scenario: Background polling for new issues
    Given the backlog was loaded 60 seconds ago
    When the poll interval elapses (configurable, default 60s)
    Then new issues matching the filter should be fetched
    And new cards should appear in "Backlog"
    And removed issues should be removed from "Backlog"

  Scenario: Polling interval is configurable
    Given settings has "github.pollIntervalSeconds": 120
    Then the background fetch should happen every 120 seconds

  # ── Starting Work on an Issue ──

  Scenario: Start work on a GitHub issue
    Given issue "#123: Fix login bug" is in the Backlog
    When I click "Start" on the card
    Then a tmux session should be created named "issue-123"
    And Claude should be launched with:
      | Flag        | Value                                    |
      | --worktree  | issue-123                                |
      | prompt      | /orchestrate Fix login bug (issue #123)  |
    And the card should move to "In Progress"

  Scenario: Skill prefix is configurable
    Given settings has "skill": "/orchestrate"
    When I start a GitHub issue
    Then the prompt should be prepended with "/orchestrate"

  Scenario: No skill prefix configured
    Given settings has no "skill" configured
    When I start a GitHub issue
    Then the prompt should just be the issue title and body

  Scenario: Issue body is included in prompt
    Given issue #123 has a body with acceptance criteria
    When I start working on it
    Then the full issue body should be included in the Claude prompt
    And it should be fetched via `gh issue view 123 --json title,body`

  # ── Edge Cases ──

  Scenario: gh CLI not installed
    Given `gh` is not installed
    When the Kanban board opens
    Then the Backlog should show a message: "Install GitHub CLI for issue integration"
    And a link to https://cli.github.com/
    And manual task creation should still work

  Scenario: gh CLI not authenticated
    Given `gh` is installed but not authenticated
    When the Kanban board opens
    Then the Backlog should show: "Run `gh auth login` to connect GitHub"
    And manual task creation should still work

  Scenario: GitHub API rate limit
    Given the GitHub API returns a rate limit error
    Then a subtle warning should appear on the Backlog column header
    And previously fetched issues should remain visible
    And retry should happen on next poll interval

  Scenario: Network offline
    Given the network is unavailable
    When a GitHub fetch fails
    Then previously cached issues should remain in the backlog
    And a subtle "offline" indicator should appear
