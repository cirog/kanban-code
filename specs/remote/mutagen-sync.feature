Feature: Mutagen File Sync
  As a developer running Claude Code remotely
  I want Kanban to manage Mutagen sync sessions
  So that my local and remote files stay in sync

  Background:
    Given the Kanban application is running
    And remote execution is configured in settings

  # ── Sync Configuration ──
  # (Learned from claude-remote: per-project named sync sessions)

  Scenario: Remote execution settings
    Given I open settings
    Then I should be able to configure:
      | Setting     | Example                          | Description                |
      | host        | ubuntu@server.com                | SSH host                   |
      | remotePath  | /home/ubuntu/Projects            | Remote base directory      |
      | localPath   | ~/Projects/remote                | Local base directory       |
    And these should be saved to ~/.kanban/settings.json

  Scenario: Starting sync for a project
    When I start work on a project at "~/Projects/remote/langwatch-saas"
    Then Mutagen sync should be started:
      """
      mutagen sync create ~/Projects/remote/langwatch-saas ubuntu@server.com:/home/ubuntu/Projects/langwatch-saas
        --name=kanban-langwatch-saas
        --label=name=kanban
        --sync-mode=two-way-resolved
        --ignore=node_modules --ignore=.venv --ignore=.next* --ignore=dist
        --default-file-mode=0644 --default-directory-mode=0755
      """
    And the sync session name should be derived from the project folder

  Scenario: Sync already running
    Given Mutagen sync is already running for "langwatch-saas"
    When I start a new session for the same project
    Then no duplicate sync should be created
    And the existing sync should be flushed before use

  # ── Sync Status Display ──

  Scenario: Displaying Mutagen status in UI
    Given a Mutagen sync session is active
    Then the UI should show the sync status:
      | Status           | Display                |
      | Watching         | Green "synced" badge   |
      | Staging changes  | Yellow "syncing" badge |
      | Paused           | Gray "paused" badge    |
      | Error            | Red "sync error" badge |
    And the status should update in real-time via `mutagen sync list`

  Scenario: Sync flush before remote commands
    Given a remote command is about to execute
    Then `mutagen sync flush --label-selector=name=kanban` should run
    And it should complete before the command executes

  Scenario: Sync flush after remote commands
    Given a remote command just completed
    Then `mutagen sync flush --label-selector=name=kanban` should run
    And it should complete before results are shown

  # ── Edge Cases ──

  Scenario: Mutagen not installed
    Given `mutagen` is not installed
    When remote execution is configured
    Then a warning should appear: "Install Mutagen for file sync"
    And a link to https://mutagen.io/
    And remote execution should still work (via SSHFS or direct SSH)

  Scenario: Sync error recovery
    Given a Mutagen sync session enters an error state
    Then the UI should show the error
    And offer "Reset sync" which runs: `mutagen sync terminate + create`
    And offer "View logs" for debugging

  Scenario: Multiple projects syncing simultaneously
    Given I'm working on 3 projects with remote execution
    Then each should have its own named Mutagen sync session
    And they should be manageable independently
    And batch operations should use `--label-selector=name=kanban`
