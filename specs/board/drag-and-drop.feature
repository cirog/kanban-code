Feature: Drag and Drop
  As a developer using Kanban
  I want to manually move cards between columns via drag and drop
  So that I can override automation when I know better

  Background:
    Given the Kanban application is running

  Scenario: Drag card between columns
    Given a card "Fix login bug" is in "In Progress"
    When I drag the card to "Requires Attention"
    Then the card should move to "Requires Attention"
    And the move should be recorded as a manual override
    And automation should still be able to move it back when state changes

  Scenario: Drag card to All Sessions (manual archive)
    Given a card is in "In Progress"
    When I drag it to "All Sessions"
    Then the card should be archived
    And it should not auto-return based on session age
    And a flag "manuallyArchived" should be set in the coordination file

  Scenario: Drag card from All Sessions to Backlog
    Given a card is in "All Sessions"
    When I drag it to "Backlog"
    Then it should appear in "Backlog"
    And the "manuallyArchived" flag should be cleared

  Scenario: Visual feedback during drag
    When I start dragging a card
    Then the card should show a drag ghost with reduced opacity
    And valid drop columns should highlight
    And invalid drop targets should show a "not allowed" indicator

  Scenario: Drag cancelled
    When I start dragging a card
    And I release it outside any column
    Then the card should animate back to its original position
    And no state changes should occur

  Scenario: Reorder cards within a column
    Given the "Backlog" column has 5 cards
    When I drag the 3rd card above the 1st card
    Then the card order should update within the column
    And the new order should persist
