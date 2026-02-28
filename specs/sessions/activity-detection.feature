Feature: Activity Detection
  As a developer managing multiple Claude sessions
  I want Kanban to accurately detect session activity state
  So that cards are in the right column at all times

  Background:
    Given the Kanban application is running
    And Claude Code hooks are installed

  # ── Hook-Based Detection ──
  # (Learned from cc-amphetamine: hooks fire on every tool use)

  Scenario: Detecting active session via hooks
    Given Claude Code hooks are configured for Kanban
    When a UserPromptSubmit hook fires for session "abc-123"
    Then the session's last_activity timestamp should update
    And the session should be considered "active"

  Scenario: Tool use keeps session alive
    Given a Claude session is actively using tools
    When PreToolUse and PostToolUse hooks fire
    Then the session's last_activity should update on each fire
    And the session should remain in "In Progress"

  Scenario: Session stop detection
    Given a Claude session stops working
    When the Stop hook fires for session "abc-123"
    Then Kanban should wait 1 second
    And if no UserPromptSubmit fires within that window
    Then the session should be flagged as "needs attention"

  Scenario: Stop followed by new prompt (anti-duplicate)
    Given the Stop hook fired for session "abc-123"
    And within 1 second, a UserPromptSubmit fires for the same session
    Then the session should remain in "In Progress"
    And no notification should be sent

  # ── Polling-Based Detection (Fallback) ──

  Scenario: Session without hooks (started externally)
    Given a Claude session was started from the user's terminal (no hooks)
    When the background process polls the .jsonl file
    And the file modification time changed in the last 60 seconds
    Then the session should be considered "active"

  Scenario: Polling the .jsonl for activity
    Given the background process checks sessions every 10 seconds
    When a session's .jsonl file has not been modified for 5 minutes
    Then the session should be considered "idle"
    And if previously in "In Progress", it may need attention

  Scenario: Detecting plan mode via transcript
    Given a Claude session enters plan mode
    When the last line in the .jsonl contains a plan approval request
    And no activity follows for 30 seconds
    Then the session should be flagged as "waiting for plan approval"

  # ── Process Detection ──

  Scenario: Checking if a Claude process is running
    Given a session "abc-123" has been idle for 10 minutes
    When checking for a running process
    Then `ps aux` should be searched for a process with this session ID
    And if found, the session is "running but waiting"
    And if not found, the session is "ended"

  Scenario: Detecting process via tmux
    Given a session is linked to tmux session "feat-login"
    When checking activity
    Then the tmux session existence confirms the terminal is open
    And the tmux session attached state shows if a user is looking at it

  # ── Activity States ──

  Scenario Outline: Activity state determination
    Given a session with the following conditions:
      | Condition             | Value         |
      | Last activity         | <last_activity> |
      | Process running       | <process>     |
      | Last hook             | <last_hook>   |
    Then the activity state should be "<state>"

    Examples:
      | last_activity | process | last_hook         | state              |
      | 10 seconds    | yes     | PreToolUse        | actively_working   |
      | 2 minutes     | yes     | Stop              | needs_attention    |
      | 2 minutes     | yes     | Notification      | needs_attention    |
      | 30 minutes    | yes     | UserPromptSubmit  | idle_waiting       |
      | 30 minutes    | no      | Stop              | ended              |
      | 25 hours      | no      | Stop              | stale              |

  # ── Column Assignment from Activity ──

  Scenario: In Progress requires hook-confirmed active session
    Given a session was last active 30 minutes ago
    But no hooks have confirmed it is actively working right now
    Then it should NOT be in "In Progress"
    And it should be in "Requires Attention" (if within 24h)
    Because "In Progress" is exclusively for Claude actively working
    And the column shows a loading spinner to make this clear

  Scenario: Recently active but idle session goes to Requires Attention
    Given a session was last active 2 hours ago
    And no activity state has been confirmed by hooks or polling
    Then it should be in "Requires Attention"
    So the user can triage it: resume, archive, or investigate

  Scenario: Only activelyWorking state puts session in In Progress
    Given a session has activityState = "actively_working"
    When the column is assigned
    Then the session goes to "In Progress"
    And a loading spinner appears in the column header

  Scenario: User can archive from Requires Attention to All Sessions
    Given a session is in "Requires Attention"
    When the user clicks "Archive" in the context menu
    Or drags the card to "All Sessions"
    Then the session moves to "All Sessions"
    And it is marked as manuallyArchived
    And it stays in All Sessions even on refresh

  # ── Idle Timeout ──

  Scenario: Configurable idle timeout
    Given settings has "sessionTimeout.activeThresholdMinutes": 1440
    When a session has been idle for 1440 minutes (24 hours)
    And it has no linked worktree or tmux session
    Then it should be auto-archived to "All Sessions"

  Scenario: Session with worktree is not auto-archived
    Given a session has been idle for 48 hours
    But it has a linked worktree that still exists
    Then it should NOT be auto-archived
    And it should remain in its current column with "idle" indicator
