Feature: Gemini CLI Activity Detection
  As a developer running Gemini CLI sessions
  I want Kanban Code to detect when Gemini is active or idle
  So that cards move to the correct columns automatically

  Background:
    Given the Kanban Code application is running
    And a Gemini session is linked to a card

  # ── Polling-Based Detection ──

  Scenario: Detect active session via file mtime
    Given a Gemini session file was modified less than 2 minutes ago
    When activity is polled
    Then the session should be reported as "activelyWorking"

  Scenario: Detect idle session via file mtime
    Given a Gemini session file was modified more than 5 minutes ago
    When activity is polled
    Then the session should be reported as "idle"

  Scenario: Detect needs-attention via stale mtime
    Given a Gemini session file was modified between 2 and 5 minutes ago
    And the last message type is "gemini" (assistant finished responding)
    When activity is polled
    Then the session should be reported as "needsAttention"

  # ── Composite Activity Detector ──

  Scenario: Route activity detection to correct assistant detector
    Given a card with assistant "gemini" and sessionId "abc"
    And a card with assistant "claude" and sessionId "xyz"
    When activity is polled for both
    Then the Gemini detector should handle "abc"
    And the Claude detector should handle "xyz"

  Scenario: Hook events are routed to correct detector
    Given a hook event with sessionId matching a "claude" card
    When the composite detector handles the event
    Then the Claude activity detector should process it
    And the Gemini detector should not be called

  # ── Session File Resolution ──

  Scenario: Find the correct session file for polling
    Given a Gemini session with id "1250be89-48ad-4418-bec4-1f40afead50e"
    And the session file is at ~/.gemini/tmp/kanban/chats/session-2026-02-25T10-30-1250be89.json
    When activity is polled for that session
    Then the detector should check the mtime of that specific file

  # ── Edge Cases ──

  Scenario: Session file deleted while session is linked
    Given a Gemini session file no longer exists on disk
    When activity is polled
    Then the session should be reported as "idle" (not crash)

  Scenario: Multiple Gemini sessions for same project
    Given 3 Gemini session files exist for the same project
    When activity is polled for a specific session
    Then only that session's file mtime should be checked
