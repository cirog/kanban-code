import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CodingAssistant Enum")
struct CodingAssistantTests {

    // MARK: - Display Names

    @Test("Claude display name")
    func claudeDisplayName() {
        #expect(CodingAssistant.claude.displayName == "Claude Code")
    }

    @Test("Gemini display name")
    func geminiDisplayName() {
        #expect(CodingAssistant.gemini.displayName == "Gemini CLI")
    }

    // MARK: - CLI Commands

    @Test("Claude CLI command")
    func claudeCliCommand() {
        #expect(CodingAssistant.claude.cliCommand == "claude")
    }

    @Test("Gemini CLI command")
    func geminiCliCommand() {
        #expect(CodingAssistant.gemini.cliCommand == "gemini")
    }

    // MARK: - Prompt Characters

    @Test("Claude prompt character is ❯")
    func claudePromptCharacter() {
        #expect(CodingAssistant.claude.promptCharacter == "❯")
    }

    @Test("Gemini prompt character detects input prompt")
    func geminiPromptCharacter() {
        #expect(CodingAssistant.gemini.promptCharacter == "Type your message")
    }

    // MARK: - Auto-Approve Flags

    @Test("Claude auto-approve flag")
    func claudeAutoApproveFlag() {
        #expect(CodingAssistant.claude.autoApproveFlag == "--dangerously-skip-permissions")
    }

    @Test("Gemini auto-approve flag")
    func geminiAutoApproveFlag() {
        #expect(CodingAssistant.gemini.autoApproveFlag == "--yolo")
    }

    // MARK: - Resume Flag

    @Test("Both assistants use --resume")
    func resumeFlag() {
        #expect(CodingAssistant.claude.resumeFlag == "--resume")
        #expect(CodingAssistant.gemini.resumeFlag == "--resume")
    }

    // MARK: - Capabilities

    @Test("Claude supports worktrees")
    func claudeSupportsWorktree() {
        #expect(CodingAssistant.claude.supportsWorktree == true)
    }

    @Test("Gemini does not support worktrees")
    func geminiNoWorktree() {
        #expect(CodingAssistant.gemini.supportsWorktree == false)
    }

    @Test("Claude supports image upload")
    func claudeSupportsImageUpload() {
        #expect(CodingAssistant.claude.supportsImageUpload == true)
    }

    @Test("Gemini does not support image upload")
    func geminiNoImageUpload() {
        #expect(CodingAssistant.gemini.supportsImageUpload == false)
    }

    // MARK: - Config Directory

    @Test("Claude config dir")
    func claudeConfigDir() {
        #expect(CodingAssistant.claude.configDirName == ".claude")
    }

    @Test("Gemini config dir")
    func geminiConfigDir() {
        #expect(CodingAssistant.gemini.configDirName == ".gemini")
    }

    // MARK: - Install Command

    @Test("Claude install command")
    func claudeInstallCommand() {
        #expect(CodingAssistant.claude.installCommand.contains("claude-code"))
    }

    @Test("Gemini install command")
    func geminiInstallCommand() {
        #expect(CodingAssistant.gemini.installCommand.contains("gemini-cli"))
    }

    // MARK: - Codable

    @Test("CodingAssistant Codable round-trip")
    func codableRoundTrip() throws {
        for assistant in CodingAssistant.allCases {
            let data = try JSONEncoder().encode(assistant)
            let decoded = try JSONDecoder().decode(CodingAssistant.self, from: data)
            #expect(decoded == assistant)
        }
    }

    @Test("CodingAssistant raw value encoding")
    func rawValueEncoding() throws {
        let data = try JSONEncoder().encode(CodingAssistant.gemini)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"gemini\"")
    }

    @Test("CodingAssistant decodes from raw string")
    func decodeFromString() throws {
        let json = "\"claude\""
        let decoded = try JSONDecoder().decode(CodingAssistant.self, from: json.data(using: .utf8)!)
        #expect(decoded == .claude)
    }

    // MARK: - CaseIterable

    @Test("CaseIterable includes all known assistants")
    func caseIterable() {
        let all = CodingAssistant.allCases
        #expect(all.contains(.claude))
        #expect(all.contains(.gemini))
        #expect(all.count == 2)
    }
}
