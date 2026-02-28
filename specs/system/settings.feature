Feature: Settings Management
  As a developer using Kanban
  I want clear, file-based settings
  So that I can configure the app and inspect/edit settings manually

  Background:
    Given the Kanban application is running

  # ── Settings File ──

  Scenario: Settings file location and format
    Then settings should be stored at ~/.kanban/settings.json
    And the file should be human-readable JSON
    And it should be editable with any text editor

  Scenario: Default settings on first run
    Given ~/.kanban/settings.json does not exist
    When I open Kanban for the first time
    Then a default settings file should be created:
      """json
      {
        "projects": [],
        "globalView": {
          "excludedPaths": []
        },
        "github": {
          "defaultFilter": "assignee:@me is:open",
          "pollIntervalSeconds": 60
        },
        "notifications": {},
        "remote": {},
        "sessionTimeout": {
          "activeThresholdMinutes": 1440
        },
        "skill": "",
        "columnOrder": ["backlog", "in_progress", "requires_attention", "in_review", "done", "all_sessions"]
      }
      """

  Scenario: Settings editor in the app
    When I open Settings in the app
    Then I should see a basic JSON editor
    And it should support:
      | Feature          | Description                    |
      | Syntax highlight | JSON syntax coloring           |
      | Validation       | Show errors for invalid JSON   |
      | Auto-save        | Save on focus loss or Cmd+S    |
    And I should also have an "Open in editor" button to use my external editor

  Scenario: Open settings externally
    When I click "Open in editor"
    Then ~/.kanban/settings.json should open in $EDITOR or the default JSON app
    And changes should be detected and reloaded when I switch back to Kanban

  Scenario: Settings hot-reload
    Given I edit ~/.kanban/settings.json externally
    When I save the file
    Then Kanban should detect the change via fs.watch
    And reload the settings without restarting
    And the UI should update to reflect new settings

  # ── Progressive Enhancement ──

  Scenario Outline: Feature availability without optional tools
    Given <tool> is <status>
    Then <feature> should be <availability>
    And a hint should <hint_status>

    Examples:
      | tool      | status          | feature              | availability | hint_status                     |
      | gh        | not installed   | GitHub integration   | disabled     | show "Install gh for GitHub"    |
      | gh        | not authed      | GitHub integration   | disabled     | show "Run gh auth login"        |
      | tmux      | not installed   | tmux integration     | disabled     | show "Install tmux for sessions"|
      | mutagen   | not installed   | file sync            | disabled     | show "Install mutagen for sync" |
      | Pushover  | not configured  | push notifications   | disabled     | show "Add Pushover keys"        |
      | gh        | installed+authed| GitHub integration   | enabled      | not show                        |
      | tmux      | installed       | tmux integration     | enabled      | not show                        |

  Scenario: Everything works without any optional tools
    Given gh, tmux, mutagen, and Pushover are all unconfigured
    Then the core Kanban board should work
    And session discovery should work (from .jsonl files)
    And card lifecycle should work (based on .jsonl polling)
    And the app should not crash or show errors

  # ── Project Configuration ──

  Scenario: Adding a project
    When I click "Add project" in settings
    Then I should be able to enter:
      | Field     | Required | Description                         |
      | path      | yes      | Project directory path              |
      | name      | no       | Display name (defaults to folder)   |
      | repoRoot  | no       | Git repo root if different from path|

  Scenario: Project with different repoRoot
    Given I add a project:
      | path      | ~/Projects/remote/langwatch-saas/langwatch |
      | repoRoot  | ~/Projects/remote/langwatch-saas           |
    Then Claude should work in "path"
    But worktrees and PRs should be tracked against "repoRoot"

  Scenario: Auto-discovering projects from Claude history
    Given Claude sessions exist for various project paths
    When I open settings
    Then discovered projects should be suggested
    And I can confirm or dismiss each suggestion

  # ── GitHub Filter Configuration ──

  Scenario: GitHub filter is raw command input
    Given I'm configuring the GitHub filter
    Then the input should accept raw gh search syntax
    And display examples:
      | "assignee:@me is:open"                    |
      | "assignee:@me repo:org/repo is:open"      |
      | "project:myorg/myproject"                  |
    And the filter should be tested when saved

  # ── Skill Configuration ──

  Scenario: Configuring the skill prefix
    Given I set the skill to "/orchestrate"
    Then when starting tasks from backlog, the prompt should be:
      "/orchestrate <task description>"

  Scenario: No skill configured
    Given the skill setting is empty
    Then tasks should be started with just the description as the prompt
