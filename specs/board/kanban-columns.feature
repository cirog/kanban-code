Feature: Kanban Board Columns
  As a developer managing multiple Claude Code sessions
  I want a native macOS kanban board with liquid glass design
  So that I can visualize and control all my AI coding work at a glance

  Background:
    Given the Kanban application is running
    And I have configured at least one project

  # ── Column Definitions ──

  Scenario: Default column layout
    When I open the Kanban board
    Then I should see the following columns in order:
      | Column             | Description                                      |
      | Backlog            | Tasks waiting to be started                       |
      | In Progress        | Claude Code sessions actively working             |
      | Requires Attention | Sessions waiting for user input                   |
      | In Review          | PRs open, waiting for review/CI                   |
      | Done               | PRs merged/closed, worktree not yet cleaned       |
      | All Sessions       | Archive of all past sessions (hideable)           |

  Scenario: All Sessions column is hidden by default
    When I open the Kanban board for the first time
    Then the "All Sessions" column should be collapsed
    And I should see a toggle button to show/hide it

  Scenario: Show All Sessions column
    Given the "All Sessions" column is hidden
    When I click the toggle to show it
    Then the "All Sessions" column should expand
    And it should display all archived sessions

  Scenario: Hide All Sessions column
    Given the "All Sessions" column is visible
    When I click the toggle to hide it
    Then the "All Sessions" column should collapse
    And other columns should expand to fill the space

  # ── Card Rendering ──

  Scenario: Card displays session metadata
    Given a session "feat/login-flow" is in the "In Progress" column
    Then the card should display:
      | Field          | Source                                         |
      | Title          | Session name or first message preview           |
      | Project        | Project folder name                             |
      | Branch         | Git branch if linked to a worktree              |
      | Session number | Human-readable #N assignment                    |
      | Time           | Relative time since last activity               |
      | Status icon    | Activity indicator (working/idle/waiting)        |

  Scenario: Card with linked PR shows PR badge
    Given a session is linked to PR #42
    Then the card should show "PR #42" with a status badge
    And the badge color should reflect the PR status:
      | PR Status          | Color   |
      | review needed      | yellow  |
      | changes requested  | red     |
      | approved           | green   |
      | CI failing         | red     |
      | CI pending         | yellow  |
      | merged             | magenta |

  Scenario: Card without a worktree shows no branch info
    Given a session running on the main branch without a worktree
    Then the card should show the project name
    And branch field should show "main" or be omitted

  Scenario: Card shows tmux indicator when tmux session exists
    Given a session is linked to tmux session "feat-login"
    And the tmux session is attached
    Then the card should show a green "tmux" indicator

  Scenario: Card shows detached tmux indicator
    Given a session is linked to tmux session "feat-login"
    And the tmux session is detached
    Then the card should show a blue "tmux" indicator

  # ── Column Scrolling and Overflow ──

  Scenario: Column with many cards scrolls independently
    Given the "All Sessions" column has 200 cards
    When I scroll within that column
    Then only that column should scroll
    And other columns should remain in their current scroll position

  Scenario: Cards are virtualized for performance
    Given the "All Sessions" column has 500 sessions
    When I scroll through the column
    Then only visible cards should be rendered in the DOM
    And scrolling should maintain 60fps

  # ── Responsive Layout ──

  Scenario: Board adapts to window resize
    When I resize the application window
    Then columns should redistribute available width
    And cards should reflow within their columns
    And no content should be clipped without scroll indicators

  Scenario: Columns can be reordered via drag
    When I drag the "In Review" column header
    And drop it before "In Progress"
    Then the column order should update
    And the new order should persist across app restarts
