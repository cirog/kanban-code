Feature: Embedded Terminal Emulator
  As a developer viewing sessions on the Kanban board
  I want a native terminal emulator embedded in each card's detail view
  So that I can interact with Claude Code without leaving the app

  Background:
    Given the Kanban application is running

  # ── Terminal Display ──

  Scenario: Opening a session's terminal
    Given a session card exists in "In Progress"
    When I click on the card
    Then a detail panel should open
    And it should contain a full terminal emulator
    And the terminal should be connected to the associated tmux session

  Scenario: Terminal is a first-class native component
    When the terminal is rendered
    Then it should use a native terminal emulator component (not a web view)
    And it should support:
      | Feature           | Required |
      | 256 colors        | yes      |
      | True color (24b)  | yes      |
      | Unicode/emoji     | yes      |
      | Mouse events      | yes      |
      | Alternate screen  | yes      |
      | Scrollback buffer | yes      |
      | Selection/copy    | yes      |
      | Paste             | yes      |
      | Font ligatures    | yes      |
    And rendering should be GPU-accelerated

  Scenario: Terminal connects to tmux session
    Given a session is linked to tmux session "feat-login"
    When I open the terminal view
    Then it should run `tmux attach-session -t feat-login`
    And I should see the current tmux output
    And I should be able to type and interact

  Scenario: Terminal shows tmux session attached elsewhere indicator
    Given a tmux session is already attached in another terminal
    When I view it in Kanban
    Then it should still show the output (tmux allows multiple clients)
    Or it should show "Session attached elsewhere" with option to force-attach

  # ── Terminal without tmux ──

  Scenario: Session without tmux shows history
    Given a session "abc-123" has no linked tmux session
    When I open the card's detail view
    Then it should show the session history (conversation transcript)
    And a "Resume" button should be available
    And the resume command should be copyable

  Scenario: Switching between terminal and history tabs
    Given a session has both a tmux session and a transcript
    Then the detail view should have tabs:
      | Tab        | Content                          |
      | Terminal   | Live tmux terminal               |
      | History    | Conversation transcript          |
      | Checkpoint | Checkpoint management            |

  # ── Resume from Terminal ──

  Scenario: Resume a session without tmux
    Given a session "abc-123" has been silent for > 5 minutes
    And no running process is detected for this session
    When I click "Resume in terminal"
    Then a new tmux session should be created
    And `claude --resume abc-123` should execute inside it
    And the terminal should attach to the new tmux session
    And the card should move to "In Progress"

  Scenario: Resume gives command to copy
    Given a session "abc-123" has no tmux session
    When I click "Copy resume command"
    Then `claude --resume abc-123` should be copied to clipboard
    And a toast should confirm "Copied"

  Scenario: Checking for running process before resume
    Given a session "abc-123" appears idle
    When I click "Resume"
    Then it should first check if a Claude process exists:
      | Check                    | Method                           |
      | Process search           | ps aux | grep session-id         |
      | tmux pane check          | tmux list-panes in linked session|
    And if a process is found, warn: "A Claude process may still be running"
    And offer to kill it before resuming

  # ── Terminal Performance ──

  Scenario: Terminal renders at native speed
    Given the terminal is displaying rapid output (e.g., test runner)
    Then rendering should maintain 60fps
    And there should be no visible lag between output and display

  Scenario: Large scrollback doesn't degrade performance
    Given a terminal with 10,000 lines of scrollback
    When I scroll through the history
    Then scrolling should be smooth
    And memory usage should be bounded

  # ── Copy tmux attach command ──

  Scenario: Copy tmux command for external terminal
    Given a session is linked to tmux session "feat-login"
    When I click "Copy tmux command"
    Then `tmux attach-session -t feat-login` should be copied to clipboard
    And I can paste it in iTerm, Terminal.app, or any terminal
