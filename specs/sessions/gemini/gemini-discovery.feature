Feature: Gemini CLI Session Discovery
  As a developer using Gemini CLI
  I want Kanban Code to discover my Gemini sessions
  So that they appear on the board alongside Claude sessions

  Background:
    Given the Kanban Code application is running
    And Gemini CLI is installed

  # ── Project Registry ──

  Scenario: Read Gemini project registry
    Given ~/.gemini/projects.json contains:
      """
      {
        "projects": {
          "/Users/rchaves/Projects/remote/kanban": "kanban",
          "/Users/rchaves/Projects/remote/scenario": "scenario"
        }
      }
      """
    When Gemini session discovery reads the registry
    Then it should map slug "kanban" to path "/Users/rchaves/Projects/remote/kanban"
    And slug "scenario" to path "/Users/rchaves/Projects/remote/scenario"

  Scenario: Missing project registry
    Given ~/.gemini/projects.json does not exist
    When Gemini session discovery runs
    Then it should return an empty session list (no crash)

  # ── Session File Scanning ──

  Scenario: Discover sessions from chats directory
    Given ~/.gemini/tmp/kanban/chats/ contains:
      | File                                           |
      | session-2026-02-25T10-30-1250be89.json         |
      | session-2026-02-25T12-28-9bdae2b0.json         |
    When Gemini session discovery runs
    Then 2 sessions should be discovered
    And each should have assistant = "gemini"

  Scenario: Parse session metadata from JSON
    Given a Gemini session file contains:
      """
      {
        "sessionId": "1250be89-48ad-4418-bec4-1f40afead50e",
        "startTime": "2026-02-25T10:30:56.393Z",
        "lastUpdated": "2026-02-25T10:31:06.666Z",
        "messages": [
          {"id": "uuid1", "type": "user", "content": [{"text": "fix the login bug"}]},
          {"id": "uuid2", "type": "gemini", "content": "I'll help fix that."}
        ],
        "summary": "Fix login bug"
      }
      """
    When the session is parsed
    Then:
      | Field         | Value                                      |
      | id            | 1250be89-48ad-4418-bec4-1f40afead50e       |
      | firstPrompt   | fix the login bug                          |
      | name          | Fix login bug                              |
      | messageCount  | 2                                          |

  Scenario: Session with zero messages is excluded
    Given a Gemini session file has "messages": []
    When Gemini session discovery runs
    Then that session should not appear in results

  Scenario: Session file with only info/error messages
    Given a Gemini session file has messages of type "info" and "error" only
    When the session is parsed
    Then messageCount should count all message types
    And the session should still be discovered

  Scenario: Project path resolution from slug
    Given ~/.gemini/projects.json maps "kanban" to "/Users/rchaves/Projects/remote/kanban"
    And a session file exists at ~/.gemini/tmp/kanban/chats/session-*.json
    When the session is discovered
    Then its projectPath should be "/Users/rchaves/Projects/remote/kanban"

  # ── Session File Path ──

  Scenario: Session file path is stored for transcript reading
    Given a session file at ~/.gemini/tmp/kanban/chats/session-2026-02-25T10-30-1250be89.json
    When it is discovered
    Then session.jsonlPath should be the full path to that JSON file
    # Note: field is named jsonlPath for legacy reasons but stores any session file path

  # ── Edge Cases ──

  Scenario: Corrupted JSON session file
    Given a session file contains invalid JSON
    When Gemini session discovery runs
    Then that file should be skipped silently
    And other valid sessions should still be discovered

  Scenario: Empty chats directory
    Given ~/.gemini/tmp/kanban/chats/ exists but is empty
    When Gemini session discovery runs
    Then it should return an empty list for that project

  Scenario: No chats directory
    Given ~/.gemini/tmp/kanban/ exists but has no chats/ subdirectory
    When Gemini session discovery runs
    Then it should skip that project gracefully
