import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("PaneOutputParser Multi-Assistant")
struct PaneOutputParserMultiAssistantTests {

    // MARK: - isReady with Claude

    @Test("isReady detects Claude prompt character")
    func isReadyClaude() {
        let output = """
        ────────────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────────────
        """
        #expect(PaneOutputParser.isReady(output, assistant: .claude) == true)
    }

    // MARK: - isClaudeReady backward compat

    @Test("isClaudeReady delegates to isReady with .claude")
    func isClaudeReadyBackwardCompat() {
        let readyOutput = "❯"
        let notReadyOutput = "loading..."
        #expect(PaneOutputParser.isClaudeReady(readyOutput) == true)
        #expect(PaneOutputParser.isClaudeReady(notReadyOutput) == false)
    }

    // MARK: - Edge cases

    @Test("Empty output is not ready for any assistant")
    func emptyOutputNotReady() {
        #expect(PaneOutputParser.isReady("", assistant: .claude) == false)
    }
}
