import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("HistoryPlusHTMLBuilder")
struct HistoryPlusHTMLBuilderTests {

    @Test("Filters out tool-use, tool-result, and thinking blocks")
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
        // Tool/thinking content NOT present
        #expect(!html.contains("file contents..."))
        #expect(!html.contains("Let me think about this..."))
        // Tool-use text NOT rendered
        #expect(!html.contains("Read /foo"))
    }

    @Test("Skips turns with no text blocks")
    func skipsTurnsWithOnlyToolBlocks() {
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
        #expect(!html.contains("ls -la"))
        #expect(!html.contains("total 0"))
        #expect(!html.contains("message"))
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

    @Test("Chat CSS contains user-msg and assistant-msg rules")
    func chatCSSContainsRules() {
        let css = HistoryPlusHTMLBuilder.chatCSS
        #expect(css.contains(".user-msg"))
        #expect(css.contains(".assistant-msg"))
        #expect(css.contains("255, 121, 198"))  // Dracula pink (#ff79c6) in rgba
    }
}
