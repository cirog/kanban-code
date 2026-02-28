Feature: PR Tracking
  As a developer with Claude Code creating PRs
  I want to see PR status on the Kanban board
  So that I know which PRs need attention

  Background:
    Given the Kanban application is running
    And `gh` CLI is installed and authenticated

  # ── PR Discovery ──
  # (Learned from git-orchard: batch fetch, branch name as key)

  Scenario: Discovering PRs via branch name
    Given a session is linked to worktree on branch "feat/issue-123"
    When the background process fetches PRs via `gh pr list`
    Then it should match the PR by headRefName == "feat/issue-123"
    And the PR should be linked to the session card

  Scenario: Batch PR fetching
    When the background process checks for PRs
    Then it should run a single `gh pr list --state all --json headRefName,number,state,title,url,reviewDecision --limit 100`
    And cache the result as Map<branchName, PrInfo>
    And NOT make individual API calls per session

  Scenario: PR enrichment via GraphQL
    Given basic PR info has been fetched
    When enrichment runs for open PRs
    Then a single GraphQL query should fetch for all open PRs:
      | Field              | Purpose                          |
      | reviewThreads      | Count unresolved review threads  |
      | statusCheckRollup  | CI check status                  |
    And the query should use field aliases (pr0, pr1, pr2...)
    And this should be a non-blocking background operation

  # ── PR Status Display ──

  Scenario: PR status badge on card
    Given a card has a linked PR
    Then the card should show a status badge:
      | PR State            | Icon | Color   | Label              |
      | CI failing          | ✕    | red     | failing            |
      | Unresolved threads  | ●    | yellow  | unresolved         |
      | Changes requested   | ✎    | red     | changes requested  |
      | Review needed       | ○    | yellow  | review needed      |
      | CI pending          | ○    | yellow  | pending            |
      | Approved            | ✓    | green   | ready              |
      | Merged              | ✓    | magenta | merged             |
      | Closed              | ✕    | red     | closed             |

  Scenario: PR status priority ordering
    Given a PR has both "CI failing" and "changes requested"
    Then the badge should show "failing" (highest priority)
    Because the priority order is: failing > unresolved > changes_requested > review_needed > pending_ci > approved

  Scenario: PR link opens in browser
    Given a card has a linked PR #42
    When I click the PR badge
    Then the PR should open in the default browser
    And the URL should be the GitHub PR URL

  # ── PR Comments ──

  Scenario: Viewing pending review comments
    Given a card is in "In Review" with PR #42
    When I click "View comments"
    Then pending review comments should be displayed
    And they should be fetched via `gh api repos/{owner}/{repo}/pulls/42/comments`
    And each comment should show author, file, line, and body

  Scenario: Unresolved thread count
    Given a PR has 3 unresolved review threads
    Then the card should show "3 unresolved" indicator
    And clicking it should show the thread summaries

  # ── CI Checks ──

  Scenario: CI check status display
    Given a PR has GitHub Actions checks
    Then the card should show a CI indicator:
      | All passing     | Green checkmark  |
      | Some failing    | Red X            |
      | Some pending    | Yellow circle    |
      | No checks       | No indicator     |

  Scenario: CI check handles both CheckRun and StatusContext
    Given a PR has both CheckRun (GitHub Actions) and StatusContext (commit status)
    Then both types should be aggregated
    And any failure from either type should show as "failing"

  # ── Edge Cases ──

  Scenario: PR from sub-repo
    Given a project with repoRoot "~/Projects/remote/langwatch-saas"
    And code changes are in subrepo "~/Projects/remote/langwatch-saas/langwatch"
    When a PR is created on "langwatch-saas"
    Then the PR should still be discovered
    Because the worktree branch is on the repoRoot

  Scenario: Multiple PRs for same branch
    Given branch "feat/login" has 2 PRs (one closed, one open)
    Then the open PR should take priority
    And the closed PR should be ignored in the active display

  Scenario: gh CLI unavailable
    Given `gh` is not installed
    Then PR tracking should be disabled gracefully
    And cards should show "Install gh for PR tracking"
    And all other Kanban features should work normally
