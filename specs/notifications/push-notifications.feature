Feature: Push Notifications
  As a developer running multiple Claude sessions
  I want push notifications when Claude needs my attention
  So that I can respond promptly without watching the screen

  Background:
    Given the Kanban application is running

  # ── Pushover Integration ──
  # (Learned from claude-pushover: token+user, image rendering, dedup)

  Scenario: Configuring Pushover
    Given I open settings
    When I enter my Pushover token and user key
    Then they should be saved to ~/.kanban/settings.json
    And a test notification should be sent to verify the keys work

  Scenario: Notification when Claude needs attention
    Given a Claude session moves to "Requires Attention"
    Then a Pushover notification should be sent with:
      | Field      | Content                                  |
      | Title      | "Claude #N: <session name>"              |
      | Message    | Last Claude response (summary)           |
      | Attachment | Rendered image of response (if multi-line)|

  Scenario: Session number in notification
    Given session "abc-123" is assigned number #3
    When a notification fires
    Then the title should start with "Claude #3:"
    And session numbers should be sequential and persist for 3 hours

  Scenario: Multi-line response rendered as image
    Given Claude's last response is multi-line with markdown
    Then the response should be rendered as a dark-theme styled image
    And sent as a Pushover image attachment
    And the image should use the system font

  Scenario: Single-line response sent as text
    Given Claude's last response is a single line
    Then it should be sent as a plain text Pushover notification
    And no image should be rendered

  # ── macOS Notifications (fallback) ──

  Scenario: macOS notification when Pushover is not configured
    Given Pushover credentials are not set
    When a session needs attention
    Then a macOS notification should be shown via osascript
    And the notification should include the session name
    And a hint to configure Pushover for phone notifications

  Scenario: macOS notification for local events
    Given any session state change occurs
    Then a macOS notification should be shown for:
      | Event                      | Always |
      | Needs attention            | yes    |
      | Task complete              | yes    |
      | Remote connection offline  | yes    |
      | Remote connection restored | yes    |

  # ── Anti-Duplicate Logic ──
  # (Learned from claude-pushover: Stop+1s delay, 62s dedup window)

  Scenario: Stop hook anti-duplicate
    Given a Stop hook fires for session "abc-123"
    When 1 second elapses
    And no UserPromptSubmit has fired for "abc-123"
    Then a notification should be sent
    And the session should move to "Requires Attention"

  Scenario: Stop followed by immediate new prompt
    Given a Stop hook fires for session "abc-123"
    And within 1 second, a UserPromptSubmit fires
    Then no notification should be sent
    And the session should remain in "In Progress"

  Scenario: Notification hook deduplication
    Given a Stop hook already sent a notification 30 seconds ago
    When a Notification hook fires for the same session
    Then the notification should be suppressed
    Because it's within the 62-second dedup window

  Scenario: Notification hook fires without prior Stop
    Given no Stop notification was sent recently
    When a Notification hook fires (e.g., permission request)
    Then a notification should be sent

  # ── Edge Cases ──

  Scenario: Pushover API unavailable
    Given the Pushover API returns an error
    Then the notification should fall back to macOS notification
    And a subtle error indicator should appear in the UI
    And retry should happen on next notification

  Scenario: Multiple sessions need attention simultaneously
    Given sessions #1, #2, and #3 all need attention within 5 seconds
    Then each should receive its own notification
    And session numbers should help distinguish them

  Scenario: Notification includes clickable action
    Given a Pushover notification is sent
    Then it should include a URL that opens the Kanban app
    And ideally deep-links to the specific session
