Feature: Review Actions
  As a developer with PRs in review
  I want to take action on review feedback from the Kanban board
  So that I can quickly address comments and keep work flowing

  Background:
    Given the Kanban application is running
    And a card is in "In Review" for PR #42

  Scenario: Address review comments via terminal
    Given the card shows 3 unresolved review threads
    When I open the terminal tab
    And I tell Claude "Address the review comments on PR #42"
    Then the card should move to "In Progress"
    And Claude should work on addressing the feedback
    And when done, the card should move back to "In Review"
    And notifications should still fire as normal

  Scenario: Skip Requires Attention when addressing review
    Given I asked Claude to address review comments
    When Claude finishes and the Stop hook fires
    Then the card should move directly to "In Review" (not "Requires Attention")
    Because the context is addressing review feedback
    And a notification should still be sent

  Scenario: Open PR in browser
    When I click "Open PR" on the card
    Then the PR URL should open in the default browser

  Scenario: Refresh PR status manually
    When I click "Refresh" on a review card
    Then PR status, CI checks, and comments should be re-fetched
    And the card should update immediately

  Scenario: PR merged from In Review
    Given the PR #42 is merged on GitHub
    When the background process detects the merge
    Then the card should move to "Done"
    And a "Clean up worktree" button should appear

  Scenario: Request re-review after addressing comments
    Given Claude addressed all review comments
    When the card is back in "In Review"
    Then I should see an indicator that new commits were pushed
    And the unresolved thread count should be refreshed
