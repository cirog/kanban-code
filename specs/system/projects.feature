Feature: Multi-Project Support
  As a developer working across multiple repositories
  I want Kanban to manage sessions from all my projects
  So that I have a unified view of all my AI coding work

  Background:
    Given the Kanban application is running

  # ── Project Views ──

  Scenario: Global view shows everything
    Given I have configured projects:
      | Name       | Path                                  |
      | LangWatch  | ~/Projects/remote/langwatch-saas      |
      | Scenario   | ~/Projects/remote/scenario            |
      | Resume     | ~/Projects/remote/claude-resume       |
    When I select the "All Projects" view
    Then sessions from all configured projects should appear on the board
    And each card should show its project name
    And columns should aggregate sessions from all projects

  Scenario: Single project view
    Given I select the "LangWatch" project view
    Then only sessions from ~/Projects/remote/langwatch-saas should appear
    And the backlog should only show issues for that project
    And the board should feel focused on that one repository

  Scenario: Switching between project views
    When I click the project selector
    Then I should see:
      | Option         | Description                      |
      | All Projects   | Combined view of everything      |
      | LangWatch      | Single project view              |
      | Scenario       | Single project view              |
      | Resume         | Single project view              |
    And switching should be instant (data is already loaded)

  # ── Global View Exclusions ──

  Scenario: Excluding projects from global view
    Given I have a personal side project at ~/Projects/personal/blog
    And I've added it to globalView.excludedPaths
    When I'm in the "All Projects" global view
    Then sessions from ~/Projects/personal/blog should not appear
    And the project should still be accessible via its single project view

  Scenario: Configuring exclusions
    When I open settings
    And I add "~/Projects/personal" to globalView.excludedPaths
    Then all projects under that path should be excluded from global view
    And pattern matching should support partial paths (prefix match)

  # ── Cross-Project Sessions ──

  Scenario: Session started in one project, working in another
    Given a session started in ~/Projects/remote/langwatch-saas/langwatch
    But it's actually making changes in ~/Projects/remote/langwatch-saas
    When the session creates a PR in the parent repo
    Then the PR should be detected for the parent repo
    And the card should show the correct repo context

  Scenario: Session switching projects mid-conversation
    Given a session started in ~/Projects/remote/langwatch-saas
    And during the conversation, the user switched to ~/Projects/remote/scenario
    When the background process detects the cwd change
    Then the session should be re-associated with the new project
    Unless there's a manual override

  # ── Undiscovered Projects ──

  Scenario: Sessions from unconfigured projects
    Given a session exists for ~/Projects/remote/new-project
    And that path is not in the configured projects list
    Then the session should still appear in the global view
    And it should be grouped under "Other" or show the raw path
    And a suggestion to add the project should appear

  Scenario: Auto-suggesting projects to add
    Given Claude sessions exist for paths not in the configured projects
    When I view the "All Projects" board
    Then a subtle banner should suggest: "Found sessions for 2 unconfigured projects"
    And clicking it should let me add them

  # ── Project-Specific Settings ──

  Scenario: Different remote config per project
    Given "LangWatch" is configured for remote execution
    And "Resume" is local-only
    Then starting a session for LangWatch should use remote shell
    And starting a session for Resume should use local shell
    And each project card should show the correct execution mode

  Scenario: Different GitHub filter per project
    Given "LangWatch" has filter "assignee:@me repo:langwatch/langwatch is:open"
    And "Scenario" has filter "assignee:@me repo:langwatch/scenario is:open"
    Then each project's backlog should show only its issues
    And the global view should combine all issues
