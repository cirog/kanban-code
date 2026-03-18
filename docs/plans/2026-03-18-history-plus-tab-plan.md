# History+ Tab Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "History+" tab to CardDetailView that renders the full conversation as a chat-style WKWebView with Dracula theme — user messages as right-aligned pink bubbles, assistant text as left-aligned Dracula-styled markdown, tool/thinking blocks filtered out.

**Architecture:** New `HistoryPlusView` (NSViewRepresentable wrapping WKWebView) reuses `ReplyTabView`'s static CSS/JS/htmlPage() infrastructure. A pure function `buildChatHTML()` transforms `[ConversationTurn]` into chat-bubble HTML. CardDetailView adds the `historyPlus` tab case with shared file watcher + polling for live updates (same pattern as history/reply tabs).

**Tech Stack:** Swift 6, SwiftUI, WKWebView, marked.js (v15.0.7), Dracula CSS, Swift Testing framework

---

### Task 1: Pure HTML Builder — `HistoryPlusHTMLBuilder`

A pure function that takes `[ConversationTurn]` and returns an HTML string. This is the core logic, fully testable without UI.

**Files:**
- Create: `Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift`
- Test: `Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift`

**Step 1: Write the failing test**

Create `Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift`:

```swift
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
        // Tool-use text NOT rendered (only text blocks from that turn)
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
        #expect(!html.contains("message"))  // no message divs at all
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
        #expect(!html.contains(">Read<"))
    }

    @Test("Returns empty string for empty input")
    func emptyInput() {
        let html = HistoryPlusHTMLBuilder.buildMessagesHTML(from: [])
        #expect(html.isEmpty)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift test --filter HistoryPlusHTMLBuilderTests 2>&1 | tail -20`
Expected: FAIL — `HistoryPlusHTMLBuilder` does not exist

**Step 3: Write minimal implementation**

Create `Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift`:

```swift
import Foundation

/// Pure function: transforms conversation turns into chat-bubble HTML for History+ tab.
/// Filters out tool-use, tool-result, and thinking blocks — only renders text.
public enum HistoryPlusHTMLBuilder {

    /// Build HTML message divs from conversation turns.
    /// Each turn becomes a div with class "message user-msg" or "message assistant-msg".
    /// Turns with no text blocks are skipped entirely.
    /// The markdown inside each div is raw — caller renders via marked.js.
    public static func buildMessagesHTML(from turns: [ConversationTurn]) -> String {
        var parts: [String] = []

        for turn in turns {
            let textBlocks = turn.contentBlocks.filter {
                if case .text = $0.kind { return true }
                return false
            }
            guard !textBlocks.isEmpty else { continue }

            let markdown = textBlocks.map(\.text).joined(separator: "\n\n")
            let escaped = markdown
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")

            let cssClass = turn.role == "user" ? "user-msg" : "assistant-msg"
            parts.append("""
            <div class="message \(cssClass)">
                <script>document.currentScript.parentElement.innerHTML = marked.parse(`\(escaped)`);</script>
            </div>
            """)
        }

        return parts.joined(separator: "\n")
    }
}
```

**Step 4: Run test to verify it passes**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift test --filter HistoryPlusHTMLBuilderTests 2>&1 | tail -20`
Expected: All 6 tests PASS

**Step 5: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard
git add Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift
git commit -m "feat: add HistoryPlusHTMLBuilder with text-only filtering"
git push
```

---

### Task 2: Chat CSS — `HistoryPlusView` static CSS

Add the chat-specific CSS (pink user bubbles, message spacing) as a static property, extending the base Dracula CSS from ReplyTabView.

**Files:**
- Create: `Sources/ClaudeBoard/HistoryPlusView.swift`
- Test: `Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift` (add CSS-related assertion)

**Step 1: Write the failing test**

Add to `Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift`:

```swift
    @Test("Chat CSS contains user-msg and assistant-msg rules")
    func chatCSSContainsRules() {
        let css = HistoryPlusHTMLBuilder.chatCSS
        #expect(css.contains(".user-msg"))
        #expect(css.contains(".assistant-msg"))
        #expect(css.contains("ff79c6"))  // Dracula pink
    }
```

Move the CSS constant to the builder (in Core) so it's testable.

**Step 2: Run test to verify it fails**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift test --filter HistoryPlusHTMLBuilderTests/chatCSSContainsRules 2>&1 | tail -20`
Expected: FAIL — `chatCSS` does not exist on `HistoryPlusHTMLBuilder`

**Step 3: Write minimal implementation**

Add to `Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift`, inside the enum:

```swift
    /// Additional CSS for chat-bubble layout (appended to ReplyTabView.css).
    public static let chatCSS: String = """
        .message {
            margin: 12px 0;
            padding: 12px 16px;
            border-radius: 12px;
            line-height: 1.6;
            overflow-wrap: break-word;
        }
        .user-msg {
            margin-left: 20%;
            text-align: left;
            font-weight: bold;
            background: rgba(255, 121, 198, 0.12);
            border: 1px solid rgba(255, 121, 198, 0.25);
        }
        .user-msg p { margin: 0.3em 0; }
        .assistant-msg {
            margin-right: 10%;
        }
        .assistant-msg:last-child { margin-bottom: 40px; }
    """
```

**Step 4: Run test to verify it passes**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift test --filter HistoryPlusHTMLBuilderTests 2>&1 | tail -20`
Expected: All 7 tests PASS

**Step 5: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard
git add Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift
git commit -m "feat: add chat-bubble CSS for History+ tab"
git push
```

---

### Task 3: `HistoryPlusView` — NSViewRepresentable with WKWebView

The SwiftUI view that wraps a WKWebView and renders the chat HTML.

**Files:**
- Create: `Sources/ClaudeBoard/HistoryPlusView.swift`

**Step 1: Write the failing test**

This is a UI component — the core logic is already tested in Task 1/2. The test here is a build test: create the view file and verify the project compiles.

No new test file needed — the build itself is the verification.

**Step 2: Write the implementation**

Create `Sources/ClaudeBoard/HistoryPlusView.swift`:

```swift
import SwiftUI
import WebKit
import ClaudeBoardCore

/// WKWebView-based chat renderer for History+ tab.
/// Shows full conversation with user messages as pink bubbles (right) and
/// assistant text as Dracula-styled markdown (left). Tool/thinking blocks filtered.
struct HistoryPlusView: NSViewRepresentable {
    let turns: [ConversationTurn]

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadHTML(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        let currentCount = turns.count
        guard currentCount != coord.lastTurnCount else { return }
        loadHTML(into: webView, coordinator: coord)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadHTML(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastTurnCount = turns.count

        let messagesHTML = HistoryPlusHTMLBuilder.buildMessagesHTML(from: turns)

        let html = ReplyTabView.htmlPage(body: """
            <style>\(HistoryPlusHTMLBuilder.chatCSS)</style>
            <div id="content">
                \(messagesHTML)
            </div>
            <script>\(ReplyTabView.markedJs)</script>
            <script>
                // marked.parse is called inline per message div (see buildMessagesHTML)
                // Auto-scroll to bottom
                window.scrollTo(0, document.body.scrollHeight);
            </script>
            """)

        webView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastTurnCount: Int = 0

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other { return .allow }
            return .cancel
        }
    }
}
```

**Step 3: Build to verify it compiles**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift build 2>&1 | tail -10`
Expected: Build succeeded

**Step 4: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard
git add Sources/ClaudeBoard/HistoryPlusView.swift
git commit -m "feat: add HistoryPlusView WKWebView component"
git push
```

---

### Task 4: Wire into CardDetailView — Tab Enum + Tab Bar + Content

Add `historyPlus` to `DetailTab`, add the tab button in the picker, add the view in the content switch, and wire up the file watcher.

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`
  - Line 11: `DetailTab` enum — add `historyPlus` case
  - Lines 1365-1383: Tab picker — add `Text("History+").tag(DetailTab.historyPlus)`
  - Lines 201-242: Content switch — add `case .historyPlus:` with `HistoryPlusView`
  - Lines 1630-1637: `handleTabChange()` — include `.historyPlus` in watcher conditions
  - Lines 258, 272, 280: `.onChange`/`.onReceive` — include `.historyPlus` in guards

**Step 1: Write the failing test**

This is a wiring task — no new pure logic to unit test. The verification is: build succeeds and the tab appears. We'll verify with a build + manual app launch.

**Step 2: Add `historyPlus` to `DetailTab` enum**

In `Sources/ClaudeBoard/CardDetailView.swift`, line 12, change:

```swift
// OLD:
case terminal, reply, history, prompt, description, summary
// NEW:
case terminal, reply, history, historyPlus, prompt, description, summary
```

**Step 3: Add tab button in the picker**

After the `Text("History").tag(DetailTab.history)` line (around line 1369), add:

```swift
if card.link.sessionLink != nil { Text("History+").tag(DetailTab.historyPlus) }
```

**Step 4: Add content view in the switch**

After the `.history` case block (around line 235), before `case .prompt:`, add:

```swift
case .historyPlus:
    HistoryPlusView(turns: turns.filter { turn in
        turn.contentBlocks.contains { if case .text = $0.kind { return true }; return false }
    })
```

Wait — the filtering is already done inside `HistoryPlusHTMLBuilder.buildMessagesHTML()`. So just pass all turns:

```swift
case .historyPlus:
    HistoryPlusView(turns: turns)
```

**Step 5: Wire file watcher to include historyPlus**

In `handleTabChange()` (line 1630), change:

```swift
// OLD:
if selectedTab == .history || selectedTab == .reply {
// NEW:
if selectedTab == .history || selectedTab == .historyPlus || selectedTab == .reply {
```

And within that block (line 1631-1633):

```swift
// OLD:
if selectedTab == .history {
    Task { await loadHistory() }
}
// NEW:
if selectedTab == .history || selectedTab == .historyPlus {
    Task { await loadHistory() }
}
```

In `.task` (around line 258):

```swift
// OLD:
if selectedTab == .history || selectedTab == .reply {
// NEW:
if selectedTab == .history || selectedTab == .historyPlus || selectedTab == .reply {
```

In `.onChange(of: card.link.sessionLink?.sessionPath)` (around line 272):

```swift
// OLD:
guard selectedTab == .history || selectedTab == .reply else { return }
// NEW:
guard selectedTab == .history || selectedTab == .historyPlus || selectedTab == .reply else { return }
```

And the `loadHistory()` call within it (line 275-276):

```swift
// OLD:
if selectedTab == .history {
// NEW:
if selectedTab == .history || selectedTab == .historyPlus {
```

In `.onReceive(NotificationCenter.default.publisher(for: .claudeBoardHistoryChanged))` (around line 280):

```swift
// OLD:
guard selectedTab == .history || selectedTab == .reply else { return }
// NEW:
guard selectedTab == .history || selectedTab == .historyPlus || selectedTab == .reply else { return }
```

And the history reload within it (line 285-286):

```swift
// OLD:
if selectedTab == .history {
// NEW:
if selectedTab == .history || selectedTab == .historyPlus {
```

**Step 6: Build to verify it compiles**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift build 2>&1 | tail -10`
Expected: Build succeeded

**Step 7: Run all tests**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift test 2>&1 | tail -20`
Expected: All tests pass (existing + new)

**Step 8: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "feat: wire History+ tab into CardDetailView with live reload"
git push
```

---

### Task 5: Deploy and Verify

Build, deploy to `/Applications/ClaudeBoard.app`, and verify the tab works.

**Step 1: Build release**

Run: `cd ~/Obsidian/MyVault/Playground/Development/ClaudeBoard && swift build 2>&1 | tail -5`

**Step 2: Kill running app**

Run: `pkill -f "ClaudeBoard.app" || true`

**Step 3: Deploy**

Run: `rm -rf /Applications/ClaudeBoard.app && cp -R ~/Obsidian/MyVault/Playground/Development/ClaudeBoard/build/ClaudeBoard.app /Applications/ClaudeBoard.app`

**Step 4: Launch**

Run: `open /Applications/ClaudeBoard.app`

**Step 5: Verify**

- Open any card with a session
- Click the "History+" tab
- Confirm: user messages appear right-aligned with pink background
- Confirm: assistant text appears left-aligned with standard Dracula styling
- Confirm: tool calls and thinking blocks are NOT shown
- Confirm: live updates work (if session is active)

**Step 6: Commit (if any fixes needed)**

```bash
git add -A && git commit -m "fix: history+ tab adjustments" && git push
```
