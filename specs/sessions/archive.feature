Feature: All Sessions Archive
  As a developer with a long history of Claude sessions
  I want to browse, search, and revive past sessions
  So that I can pick up old work or reference past solutions

  Background:
    Given the Kanban Code application is running

  Scenario: All Sessions contains unlinked past sessions
    Given sessions exist that are not in any other column
    And they have no active worktree, tmux session, or recent activity
    Then they should appear in the "All Sessions" column

  Scenario: All Sessions shows sessions from all projects
    Given I have sessions from:
      | Project                        |
      | langwatch-saas                 |
      | scenario                       |
      | claude-resume                  |
    When I view "All Sessions"
    Then sessions from all projects should be visible
    And they should be sorted by most recently modified

  Scenario: All Sessions is virtualized
    Given there are 500+ sessions in "All Sessions"
    When I scroll through the column
    Then only visible cards should be rendered
    And scrolling should be smooth at 60fps
    And memory usage should not grow linearly with session count

  Scenario: Reviving a session by sending a message
    Given an archived session "abc-123" is in "All Sessions"
    When I click on it and send a message via the terminal
    Then a tmux session should be created
    And Claude should be resumed with `claude --resume abc-123`
    And the card should move to "In Progress"
    And the manuallyArchived flag should be cleared

  Scenario: Revived session goes to waiting when work stops
    Given a previously archived session that was revived by sending a message
    And the manuallyArchived flag was cleared when it moved to "In Progress"
    When Claude stops working and needs attention
    Then the card should move to "Waiting"
    And it should NOT fall back to "All Sessions"

  Scenario: Archived card stays archived when idle
    Given an archived session "abc-123" is in "All Sessions"
    And the session receives an idle activity state update
    Then the card should remain in "All Sessions"
    And the manuallyArchived flag should remain set

  Scenario: Reviving with one-click resume button
    Given an archived session card
    When I click the "Resume" button
    Then a tmux session should be created
    And `claude --resume abc-123` should execute inside it
    And the card should move to "In Progress"

  Scenario: Reviving gives resume command to copy
    Given an archived session card
    When I click "Copy resume command"
    Then `claude --resume abc-123` should be in the clipboard
    And I can paste it in my own terminal

  Scenario: Reviving does not create a worktree by default
    Given I resume a session from All Sessions
    When Claude starts
    Then it should resume in the original project directory
    And no new worktree should be created
    And if I want a worktree, I can ask Claude to create one

  Scenario: Filtering All Sessions by project
    Given "All Sessions" contains sessions from multiple projects
    When I click a project filter chip
    Then only sessions from that project should be shown
    And other project chips should be deselected

  Scenario: All Sessions shows session metadata
    Given archived sessions exist
    Then each card should show:
      | Field        | Source                           |
      | Title        | Custom name or first message     |
      | Project      | Project folder name              |
      | Last active  | Relative time                    |
      | Messages     | Total message count              |
