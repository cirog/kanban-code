import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("HistoryPlusHTMLBuilder")
struct HistoryPlusHTMLBuilderTests {

    @Test("Activity lines hidden when followed by text; tool-result and thinking always hidden")
    func filtersNonTextBlocks() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Hello",
                contentBlocks: [ContentBlock(kind: .text, text: "Hello")]
            ),
            ConversationTurn(
                index: 1, lineNumber: 1, role: "assistant",
                textPreview: "Let me read that file.",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "Let me read that file."),
                    ContentBlock(kind: .toolUse(name: "Read", input: ["path": "/foo"]), text: "Read /foo"),
                ]
            ),
            ConversationTurn(
                index: 2, lineNumber: 2, role: "assistant",
                textPreview: "Tool result",
                contentBlocks: [
                    ContentBlock(kind: .toolResult(toolName: "Read"), text: "file contents..."),
                ]
            ),
            ConversationTurn(
                index: 3, lineNumber: 3, role: "assistant",
                textPreview: "Thinking...",
                contentBlocks: [
                    ContentBlock(kind: .thinking, text: "Let me think about this..."),
                ]
            ),
            ConversationTurn(
                index: 4, lineNumber: 4, role: "assistant",
                textPreview: "Here is the fix.",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "Here is the fix."),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)

        // User message present
        #expect(html.contains("Hello"))
        // Assistant text blocks present
        #expect(html.contains("Let me read that file."))
        #expect(html.contains("Here is the fix."))
        // Activity lines hidden — text follows in turn 4
        #expect(!html.contains("activity-msg"))
        // Tool-result and thinking content NOT present
        #expect(!html.contains("file contents..."))
        #expect(!html.contains("Let me think about this..."))
    }

    @Test("Visible tool-only turns render as activity, not as assistant messages")
    func visibleToolOnlyTurns() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "Tool only",
                contentBlocks: [
                    ContentBlock(kind: .toolUse(name: "Bash", input: [:]), text: "ls -la"),
                    ContentBlock(kind: .toolResult(toolName: "Bash"), text: "total 0"),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        // Bash is a visible tool → activity-msg present
        #expect(html.contains("activity-msg"))
        #expect(html.contains("Running"))
        // Tool result content NOT rendered
        #expect(!html.contains("total 0"))
        // No assistant-msg bubble (no text blocks)
        #expect(!html.contains("assistant-msg"))
    }

    @Test("User messages get user-msg class")
    func userMessageClass() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Fix the bug",
                contentBlocks: [ContentBlock(kind: .text, text: "Fix the bug")]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.contains("user-msg"))
        #expect(!html.contains("assistant-msg"))
    }

    @Test("Assistant messages get assistant-msg class")
    func assistantMessageClass() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "Done!",
                contentBlocks: [ContentBlock(kind: .text, text: "Done!")]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.contains("assistant-msg"))
        #expect(!html.contains("user-msg"))
    }

    @Test("Concatenates multiple text blocks in one turn")
    func concatenatesTextBlocks() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "Part one",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "Part one."),
                    ContentBlock(kind: .toolUse(name: "Read", input: [:]), text: "Read"),
                    ContentBlock(kind: .text, text: "Part two."),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.contains("Part one."))
        #expect(html.contains("Part two."))
    }

    @Test("Returns empty string for empty input")
    func emptyInput() {
        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: [])
        #expect(html.isEmpty)
    }

    @Test("Uses data-md attributes instead of inline scripts for deferred rendering")
    func usesDataAttributes() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Hello",
                contentBlocks: [ContentBlock(kind: .text, text: "Hello")]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        // Must use data-md attribute (not inline <script>) so marked.js can be loaded first
        #expect(html.contains("data-md="))
        #expect(!html.contains("<script>"))
    }

    @Test("Skill invocation turns get skill-msg class")
    func skillInvocationClass() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "superpowers:brainstorming build a feature",
                contentBlocks: [ContentBlock(kind: .text, text: "superpowers:brainstorming build a feature")]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.contains("skill-msg"))
        #expect(!html.contains("user-msg"))
    }

    @Test("Skill tool_use blocks get skill-msg class")
    func skillToolUseClass() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "Skill(obsidian:obsidian-cli)",
                contentBlocks: [
                    ContentBlock(kind: .toolUse(name: "Skill", input: ["skill": "obsidian:obsidian-cli"]), text: "Skill(obsidian:obsidian-cli)"),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.contains("skill-msg"))
        #expect(!html.contains("assistant-msg"))
    }

    @Test("Chat CSS contains skill-msg rules with cyan color")
    func chatCSSContainsSkillRules() {
        let css = HistoryPlusHTMLBuilder.chatCSS
        #expect(css.contains(".skill-msg"))
        #expect(css.contains("139, 233, 253"))  // Dracula cyan (#8be9fd) in rgba
    }

    @Test("URL-like patterns are NOT detected as skill invocations")
    func urlPatternsNotSkill() {
        let cases = [
            "http:something",
            "https://example.com",
            "ftp://server.local/file",
            "mailto:user@example.com",
        ]
        for text in cases {
            let turns: [ConversationTurn] = [
                ConversationTurn(
                    index: 0, lineNumber: 0, role: "user",
                    textPreview: text,
                    contentBlocks: [ContentBlock(kind: .text, text: text)]
                ),
            ]
            let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
            #expect(!html.contains("skill-msg"), "'\(text)' should NOT be a skill-msg")
            #expect(html.contains("user-msg"), "'\(text)' should be a normal user-msg")
        }
    }

    @Test("Short namespace like 're:' is NOT detected as skill")
    func shortNamespaceNotSkill() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "re:meeting notes",
                contentBlocks: [ContentBlock(kind: .text, text: "re:meeting notes")]
            ),
        ]
        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(!html.contains("skill-msg"))
        #expect(html.contains("user-msg"))
    }

    @Test("Valid skill pattern ic:daily-check still detected")
    func validSkillStillDetected() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "ic:daily-check",
                contentBlocks: [ContentBlock(kind: .text, text: "ic:daily-check")]
            ),
        ]
        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.contains("skill-msg"))
        #expect(!html.contains("user-msg"))
    }

    @Test("Chat CSS contains user-msg and assistant-msg rules")
    func chatCSSContainsRules() {
        let css = HistoryPlusHTMLBuilder.chatCSS
        #expect(css.contains(".user-msg"))
        #expect(css.contains(".assistant-msg"))
        #expect(css.contains("255, 121, 198"))  // Dracula pink (#ff79c6) in rgba
    }

    // MARK: - Tool Activity Indicators

    @Test("Hidden bookkeeping tools produce no output")
    func hiddenToolsAreFiltered() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "TaskCreate",
                contentBlocks: [
                    ContentBlock(kind: .toolUse(name: "TaskCreate", input: ["subject": "Do stuff"]), text: "TaskCreate(Do stuff)"),
                    ContentBlock(kind: .toolUse(name: "TaskUpdate", input: ["taskId": "1"]), text: "TaskUpdate(1)"),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.isEmpty)
    }

    @Test("Trailing tool activity after text is shown (last content in conversation)")
    func trailingActivityAfterTextShown() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "I found the issue.",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "I found the issue."),
                    ContentBlock(kind: .toolUse(name: "Read", input: ["file_path": "foo.swift"]), text: "Read(.../foo.swift)"),
                    ContentBlock(kind: .toolUse(name: "Edit", input: ["file_path": "foo.swift"]), text: "Edit(.../foo.swift)"),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        // Text bubble present
        #expect(html.contains("assistant-msg"))
        #expect(html.contains("I found the issue."))
        // Activity shown — these are trailing (nothing follows)
        #expect(html.contains("activity-msg"))
        #expect(html.contains("Reading"))
        #expect(html.contains("Editing"))
    }

    @Test("Activity hidden when followed by text in a later turn")
    func activityHiddenWhenTextFollows() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "Reading",
                contentBlocks: [
                    ContentBlock(kind: .toolUse(name: "Read", input: [:]), text: "Read(file.swift)"),
                    ContentBlock(kind: .toolUse(name: "Grep", input: [:]), text: "Grep(pattern)"),
                ]
            ),
            ConversationTurn(
                index: 1, lineNumber: 1, role: "assistant",
                textPreview: "Found it!",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "Found it!"),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        // Text present
        #expect(html.contains("Found it!"))
        // Activity hidden — text follows
        #expect(!html.contains("activity-msg"))
    }

    @Test("Activity indicators use gerund labels for known tools")
    func activityMsgUsesGerundLabel() {
        let tools: [(String, String)] = [
            ("Read", "Reading"),
            ("Write", "Writing"),
            ("Edit", "Editing"),
            ("Bash", "Running"),
            ("Grep", "Searching"),
            ("Glob", "Finding files"),
            ("Agent", "Delegating"),
            ("WebFetch", "Fetching"),
            ("WebSearch", "Searching web"),
        ]
        for (toolName, expectedGerund) in tools {
            let turns: [ConversationTurn] = [
                ConversationTurn(
                    index: 0, lineNumber: 0, role: "assistant",
                    textPreview: toolName,
                    contentBlocks: [
                        ContentBlock(kind: .toolUse(name: toolName, input: [:]), text: "\(toolName)(args)"),
                    ]
                ),
            ]
            let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
            #expect(html.contains(expectedGerund), "Tool '\(toolName)' should produce gerund '\(expectedGerund)'")
        }
    }

    @Test("Chat CSS contains activity-msg rules with Dracula green")
    func chatCSSContainsActivityMsgRules() {
        let css = HistoryPlusHTMLBuilder.chatCSS
        #expect(css.contains(".activity-msg"))
        #expect(css.contains("80, 250, 123"))  // Dracula green (#50fa7b) in rgba
    }

    @Test("Skill tool_use takes priority over activity indicator")
    func skillTurnsTakePriorityOverActivity() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "Skill(ic:status)",
                contentBlocks: [
                    ContentBlock(kind: .toolUse(name: "Skill", input: ["skill": "ic:status"]), text: "Skill(ic:status)"),
                    ContentBlock(kind: .toolUse(name: "Read", input: [:]), text: "Read(file)"),
                ]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.contains("skill-msg"))
        #expect(!html.contains("activity-msg"))
    }

    @Test("Thinking-only and toolResult-only turns produce no output")
    func thinkingAndToolResultStillHidden() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "assistant",
                textPreview: "Thinking",
                contentBlocks: [ContentBlock(kind: .thinking, text: "deep thought")]
            ),
            ConversationTurn(
                index: 1, lineNumber: 1, role: "assistant",
                textPreview: "Result",
                contentBlocks: [ContentBlock(kind: .toolResult(toolName: "Bash"), text: "output")]
            ),
        ]

        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)
        #expect(html.isEmpty)
    }

    // MARK: - Session Dividers

    @Test("Session divider HTML is generated correctly")
    func sessionDividerHTML() {
        let divider = HistoryPlusHTMLBuilder.buildSessionDividerHTML(
            reason: "Resumed", gap: "2h gap", timestamp: "Mar 21, 14:30"
        )
        #expect(divider.contains("session-divider"))
        #expect(divider.contains("Resumed"))
        #expect(divider.contains("2h gap"))
        #expect(divider.contains("Mar 21, 14:30"))
    }

    @Test("Session divider without gap omits gap text")
    func sessionDividerNoGap() {
        let divider = HistoryPlusHTMLBuilder.buildSessionDividerHTML(
            reason: "Started", gap: nil, timestamp: "Mar 21, 09:00"
        )
        #expect(divider.contains("Started"))
        #expect(!divider.contains("gap"))
    }

    @Test("Segmented messages HTML includes dividers between groups")
    func segmentedMessagesHTML() {
        let turns1 = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Hello",
                contentBlocks: [ContentBlock(kind: .text, text: "Hello")]
            ),
        ]
        let turns2 = [
            ConversationTurn(
                index: 1, lineNumber: 1, role: "assistant",
                textPreview: "World",
                contentBlocks: [ContentBlock(kind: .text, text: "World")]
            ),
        ]
        let dividerHTML = HistoryPlusHTMLBuilder.buildSessionDividerHTML(
            reason: "Resumed", gap: "1h gap", timestamp: "Mar 21, 10:00"
        )
        let segments: [(dividerHTML: String?, turns: [ConversationTurn])] = [
            (nil, turns1),
            (dividerHTML, turns2),
        ]
        let html = HistoryPlusHTMLBuilder.buildSegmentedMessagesHTML(segments: segments)
        #expect(html.contains("Hello"))
        #expect(html.contains("World"))
        #expect(html.contains("session-divider"))
        #expect(html.contains("Resumed"))
    }

    @Test("Chat CSS contains session-divider rules")
    func chatCSSContainsDividerRules() {
        let css = HistoryPlusHTMLBuilder.chatCSS
        #expect(css.contains(".session-divider"))
        #expect(css.contains(".divider-line"))
        #expect(css.contains(".divider-text"))
    }

    // MARK: - Prompts HTML Builder

    @Test("Prompts HTML renders prompt entries with data-md and timestamp")
    func promptsHTMLBasic() {
        let prompts = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Fix the bug",
                timestamp: "2026-03-22T10:00:00Z",
                contentBlocks: [ContentBlock(kind: .text, text: "Fix the bug")]
            ),
        ]
        let groups: [(sessionLabel: String, dividerHTML: String?, prompts: [ConversationTurn])] = [
            ("Current session", nil, prompts),
        ]
        let html = HistoryPlusHTMLBuilder.buildPromptsHTML(groups: groups)
        #expect(html.contains("prompt-entry"))
        #expect(html.contains("prompt-ts"))
        #expect(html.contains("prompt-body"))
        #expect(html.contains("data-md="))
        #expect(html.contains("Fix the bug"))
        #expect(html.contains("2026-03-22T10:00:00Z"))
    }

    @Test("Prompts HTML skips turns with no text blocks")
    func promptsHTMLSkipsNonText() {
        let prompts = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Tool result",
                contentBlocks: [ContentBlock(kind: .toolResult(toolName: "Bash"), text: "output")]
            ),
        ]
        let groups: [(sessionLabel: String, dividerHTML: String?, prompts: [ConversationTurn])] = [
            ("Current session", nil, prompts),
        ]
        let html = HistoryPlusHTMLBuilder.buildPromptsHTML(groups: groups)
        #expect(!html.contains("prompt-entry"))
    }

    @Test("Prompts HTML single group does NOT wrap in details")
    func promptsHTMLSingleGroupNoDetails() {
        let prompts = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Hello",
                contentBlocks: [ContentBlock(kind: .text, text: "Hello")]
            ),
        ]
        let groups: [(sessionLabel: String, dividerHTML: String?, prompts: [ConversationTurn])] = [
            ("Current session", nil, prompts),
        ]
        let html = HistoryPlusHTMLBuilder.buildPromptsHTML(groups: groups)
        #expect(!html.contains("<details"))
        #expect(!html.contains("</details>"))
        #expect(!html.contains("session-header"))
    }

    @Test("Prompts HTML multiple groups use collapsible details sections")
    func promptsHTMLMultipleGroupsCollapsible() {
        let prompts1 = [
            ConversationTurn(
                index: 0, lineNumber: 0, role: "user",
                textPreview: "Hello",
                contentBlocks: [ContentBlock(kind: .text, text: "Hello")]
            ),
        ]
        let prompts2 = [
            ConversationTurn(
                index: 1, lineNumber: 1, role: "user",
                textPreview: "World",
                contentBlocks: [ContentBlock(kind: .text, text: "World")]
            ),
        ]
        let divider = HistoryPlusHTMLBuilder.buildSessionDividerHTML(
            reason: "Resumed", gap: "1h gap", timestamp: "10:00"
        )
        let groups: [(sessionLabel: String, dividerHTML: String?, prompts: [ConversationTurn])] = [
            ("Session 1", nil, prompts1),
            ("Session 2", divider, prompts2),
        ]
        let html = HistoryPlusHTMLBuilder.buildPromptsHTML(groups: groups)
        // First group closed, last group open
        #expect(html.contains("<details >"))   // first group NOT open
        #expect(html.contains("details open"))  // last group open
        #expect(html.contains("session-header"))
        #expect(html.contains("Session 1"))
        #expect(html.contains("Session 2"))
        #expect(html.contains("session-divider"))
        #expect(html.contains("Hello"))
        #expect(html.contains("World"))
    }

    @Test("Prompts HTML returns empty for empty groups")
    func promptsHTMLEmpty() {
        let html = HistoryPlusHTMLBuilder.buildPromptsHTML(groups: [])
        #expect(html.isEmpty)
    }

    @Test("Prompts CSS contains required classes")
    func promptsCSSContainsRules() {
        let css = HistoryPlusHTMLBuilder.promptsCSS
        #expect(css.contains(".session-header"))
        #expect(css.contains(".prompt-entry"))
        #expect(css.contains(".prompt-ts"))
        #expect(css.contains(".prompt-body"))
    }
}
