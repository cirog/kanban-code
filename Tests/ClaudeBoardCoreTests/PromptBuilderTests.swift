import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("PromptBuilder")
struct PromptBuilderTests {

    @Test("Manual task uses promptBody as-is")
    func manualTaskPrompt() {
        let link = Link(
            name: "Fix the bug",
            source: .manual,
            promptBody: "Fix the authentication bug in the login flow"
        )
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt == "Fix the authentication bug in the login flow")
    }




    @Test("Prompt template wraps the result")
    func promptTemplateWraps() {
        let link = Link(
            name: "Fix bug",
            source: .manual,
            promptBody: "Fix the bug"
        )
        let settings = Settings(promptTemplate: "You are a senior engineer. ${prompt}")
        let prompt = PromptBuilder.buildPrompt(card: link, settings: settings)
        #expect(prompt == "You are a senior engineer. Fix the bug")
    }

    @Test("Session card uses name as-is")
    func sessionCardUsesName() {
        let link = Link(
            name: "Implement feature X",
            slug: "s1"
        )
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt == "Implement feature X")
    }

    @Test("Card with no name or body returns empty")
    func emptyCard() {
        let link = Link(source: .discovered)
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt.isEmpty)
    }

    @Test("Name-only card returns name from buildPrompt — caller decides whether to send")
    func nameOnlyCardReturnsName() {
        let link = Link(name: "My Task", source: .manual)
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt == "My Task")
    }

    @Test("Prompt template without placeholder prepends to prompt")
    func promptTemplateWithoutPlaceholder() {
        let link = Link(
            name: "Fix bug",
            source: .manual,
            promptBody: "Fix the auth bug"
        )
        let settings = Settings(promptTemplate: "You are a senior engineer.")
        let prompt = PromptBuilder.buildPrompt(card: link, settings: settings)
        #expect(prompt == "You are a senior engineer.\nFix the auth bug")
    }

    @Test("applyTemplate replaces variables")
    func templateVariables() {
        let result = PromptBuilder.applyTemplate(
            "Hello ${name}, you have ${count} items",
            variables: ["name": "Alice", "count": "3"]
        )
        #expect(result == "Hello Alice, you have 3 items")
    }

    @Test("applyTemplate handles missing variables")
    func templateMissingVars() {
        let result = PromptBuilder.applyTemplate(
            "Hello ${name}, ${missing} here",
            variables: ["name": "Bob"]
        )
        #expect(result == "Hello Bob, ${missing} here")
    }
}
