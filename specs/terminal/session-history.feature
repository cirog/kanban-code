Feature: Session History View
  As a developer reviewing past sessions
  I want to see the full conversation transcript
  So that I can understand what happened and decide on next steps

  Background:
    Given the Kanban application is running

  Scenario: Viewing session history
    Given a session "abc-123" exists
    When I open the card and switch to the "History" tab
    Then I should see all conversation turns in chronological order
    And each turn should show:
      | Field     | Description                          |
      | Role      | "You" or "Claude"                    |
      | Content   | Full message text (rendered markdown) |
      | Timestamp | When the message was sent            |
      | Turn #    | Sequential turn number               |

  Scenario: Tool use messages in history
    Given an assistant message contains tool_use blocks
    Then the history should show the tool name and a summary
    And tool_result responses should show the result summary
    And tool details should be collapsible

  Scenario: History scrolls to latest by default
    When I open the history view
    Then it should scroll to the most recent message
    And I should be able to scroll up to see earlier messages

  Scenario: History supports search
    When I press Cmd+F in the history view
    Then a search bar should appear
    And I can search within the conversation transcript
    And matches should be highlighted

  Scenario: History with checkpoint context
    Given I'm viewing session history
    When I right-click on a turn
    Then I should see an option "Checkpoint to here"
    And selecting it should open the checkpoint confirmation dialog

  Scenario: History loads lazily for large sessions
    Given a session has 5000 conversation turns
    When I open the history view
    Then only the last 100 turns should be loaded initially
    And scrolling up should load more turns incrementally
    And the view should never freeze
