Feature: Gemini Session Transcript Reading
  As a developer viewing Gemini session history
  I want to read Gemini session transcripts in the history view
  So that I can review what Gemini did

  Background:
    Given the Kanban Code application is running
    And a Gemini session file exists

  # ── Message Type Mapping ──

  Scenario: User messages are mapped correctly
    Given a Gemini message with type "user" and content [{"text": "hello"}]
    When the transcript is read
    Then a ConversationTurn with role "user" and text "hello" should be produced

  Scenario: Gemini (assistant) messages are mapped
    Given a Gemini message with type "gemini" and content "Here's the fix..."
    When the transcript is read
    Then a ConversationTurn with role "assistant" and text "Here's the fix..." should be produced

  Scenario: Info messages are included
    Given a Gemini message with type "info" and content "Model set to gemini-3.1-pro"
    When the transcript is read
    Then a ConversationTurn should be produced for it

  Scenario: Error messages are included
    Given a Gemini message with type "error" and content "[API Error: ...]"
    When the transcript is read
    Then a ConversationTurn should be produced for it

  # ── Tool Calls ──

  Scenario: Tool calls are rendered as content blocks
    Given a Gemini message has toolCalls:
      """
      [{
        "id": "read_file_123",
        "name": "read_file",
        "args": {"target_file": "src/main.ts"},
        "status": "completed",
        "result": [{"functionResponse": {"response": {"output": "file contents..."}}}]
      }]
      """
    When the transcript is read
    Then the ConversationTurn should include a toolUse content block for "read_file"

  Scenario: Tool call with error status
    Given a Gemini tool call has status "cancelled"
    When the transcript is read
    Then the content block should indicate the cancellation

  # ── Thinking/Thoughts ──

  Scenario: Thoughts are rendered as thinking blocks
    Given a Gemini message has thoughts:
      """
      [{"subject": "Analyzing code", "description": "Looking at the structure...", "timestamp": "..."}]
      """
    When the transcript is read
    Then the ConversationTurn should include a thinking content block
    And the thinking text should include the subject and description

  # ── Token Info ──

  Scenario: Token usage is available per message
    Given a Gemini message has tokens: {"input": 1000, "output": 50, "total": 1050}
    When the transcript is read
    Then token information should be accessible on the turn

  # ── Fork Session ──

  Scenario: Fork a Gemini session
    Given a Gemini session file with 5 messages
    When the session is forked
    Then a new JSON file should be created with a new sessionId
    And it should contain the same 5 messages
    And the original file should be unchanged

  Scenario: Fork to a different directory
    Given a Gemini session at ~/.gemini/tmp/kanban/chats/session-abc.json
    When forked with targetDirectory "/tmp/test/"
    Then the new file should be in /tmp/test/

  # ── Truncate Session ──

  Scenario: Truncate (checkpoint) a Gemini session
    Given a Gemini session with 10 messages
    When truncated after turn index 5
    Then a .bkp backup should be created
    And the session file should contain only the first 5 messages

  # ── Search Sessions ──

  Scenario: Full-text search across Gemini sessions
    Given multiple Gemini session files exist
    And one contains the text "kubernetes deployment"
    When searching for "kubernetes"
    Then the session containing that text should be returned with snippets

  Scenario: Search handles user content array format
    Given a Gemini user message has content: [{"text": "fix the navbar"}]
    When searching for "navbar"
    Then that session should match

  Scenario: Search handles assistant string content format
    Given a Gemini assistant message has content: "I've fixed the navbar"
    When searching for "navbar"
    Then that session should match
