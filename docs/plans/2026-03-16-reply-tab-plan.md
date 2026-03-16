# Reply Tab Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "Reply" tab to ClaudeBoard that shows the last assistant turn's text blocks rendered as styled markdown in a WKWebView with Dracula theme.

**Architecture:** New `DetailTab.reply` case + `ReplyTabView` (NSViewRepresentable wrapping WKWebView). Markdown rendered client-side via `marked.min.js` embedded as a Swift string constant. New `TranscriptReader.lastAssistantTextBlocks()` method extracts only `.text` blocks from the last assistant turn. Tab renders on focus, caches by turn index.

**Tech Stack:** Swift 6, SwiftUI, WebKit (WKWebView), marked.js (embedded), CSS (Dracula)

---

### Task 1: Add `lastAssistantTextBlocks` to TranscriptReader

**Files:**
- Modify: `Sources/ClaudeBoardCore/Adapters/ClaudeCode/TranscriptReader.swift`
- Test: `Tests/ClaudeBoardCoreTests/TranscriptReaderTests.swift`

**Step 1: Write the failing test**

Add to `TranscriptReaderTests.swift`:

```swift
func testLastAssistantTextBlocks_returnsOnlyTextBlocks() async throws {
    // Create a temp .jsonl file with an assistant turn containing text + tool_use blocks
    let jsonl = """
    {"type":"user","message":{"content":[{"type":"text","text":"hello"}]},"timestamp":"2026-03-16T10:00:00Z"}
    {"type":"assistant","message":{"content":[{"type":"text","text":"Here is the result:"},{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"ls"}},{"type":"text","text":"| Col A | Col B |\\n|-------|-------|\\n| 1 | 2 |"}]},"timestamp":"2026-03-16T10:00:01Z"}
    """
    let path = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try await TranscriptReader.lastAssistantTextBlocks(from: path)

    XCTAssertNotNil(result)
    XCTAssertEqual(result?.turnIndex, 1)
    XCTAssertEqual(result?.texts.count, 2)
    XCTAssertEqual(result?.texts[0], "Here is the result:")
    XCTAssertTrue(result?.texts[1].contains("Col A") == true)
}

func testLastAssistantTextBlocks_emptyFile() async throws {
    let path = writeTempFile("")
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try await TranscriptReader.lastAssistantTextBlocks(from: path)
    XCTAssertNil(result)
}

func testLastAssistantTextBlocks_noTextBlocks() async throws {
    // Assistant turn with only tool_use, no text
    let jsonl = """
    {"type":"user","message":{"content":[{"type":"text","text":"do it"}]},"timestamp":"2026-03-16T10:00:00Z"}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","id":"t1","input":{"file_path":"/tmp/x"}}]},"timestamp":"2026-03-16T10:00:01Z"}
    """
    let path = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try await TranscriptReader.lastAssistantTextBlocks(from: path)
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.texts.count, 0)
}

func testLastAssistantTextBlocks_picksLastAssistant() async throws {
    // Two assistant turns — should return the second one
    let jsonl = """
    {"type":"user","message":{"content":[{"type":"text","text":"first"}]},"timestamp":"2026-03-16T10:00:00Z"}
    {"type":"assistant","message":{"content":[{"type":"text","text":"first reply"}]},"timestamp":"2026-03-16T10:00:01Z"}
    {"type":"user","message":{"content":[{"type":"text","text":"second"}]},"timestamp":"2026-03-16T10:00:02Z"}
    {"type":"assistant","message":{"content":[{"type":"text","text":"second reply"}]},"timestamp":"2026-03-16T10:00:03Z"}
    """
    let path = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try await TranscriptReader.lastAssistantTextBlocks(from: path)
    XCTAssertEqual(result?.texts, ["second reply"])
}
```

Note: If `writeTempFile` helper doesn't exist yet, add it:
```swift
private func writeTempFile(_ content: String) -> String {
    let path = NSTemporaryDirectory() + "test-\(UUID().uuidString).jsonl"
    try! content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptReaderTests`
Expected: FAIL — `lastAssistantTextBlocks` doesn't exist yet

**Step 3: Write minimal implementation**

Add to `TranscriptReader.swift`:

```swift
/// Result of extracting text blocks from the last assistant turn.
public struct LastReplyResult: Sendable {
    public let turnIndex: Int
    public let texts: [String]
}

/// Extract only the `.text` content blocks from the last assistant turn.
/// Returns nil if no assistant turns exist.
public static func lastAssistantTextBlocks(from filePath: String) async throws -> LastReplyResult? {
    guard FileManager.default.fileExists(atPath: filePath) else { return nil }

    let url = URL(fileURLWithPath: filePath)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var lastAssistantLine: String?
    var lastAssistantIndex = -1
    var turnIndex = 0

    for try await line in handle.bytes.lines {
        guard !line.isEmpty, line.contains("\"type\"") else { continue }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "user" || type == "assistant" else { continue }

        if type == "user" && JsonlParser.isCaveatMessage(obj) { continue }

        if type == "assistant" {
            lastAssistantLine = line
            lastAssistantIndex = turnIndex
        }
        turnIndex += 1
    }

    guard let line = lastAssistantLine else { return nil }

    // Parse the content blocks, extracting only text
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = obj["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]] else {
        return LastReplyResult(turnIndex: lastAssistantIndex, texts: [])
    }

    let texts = content.compactMap { block -> String? in
        guard let type = block["type"] as? String, type == "text",
              let text = block["text"] as? String else { return nil }
        return text
    }

    return LastReplyResult(turnIndex: lastAssistantIndex, texts: texts)
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter TranscriptReaderTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/Adapters/ClaudeCode/TranscriptReader.swift Tests/ClaudeBoardCoreTests/TranscriptReaderTests.swift
git commit -m "feat: add lastAssistantTextBlocks to TranscriptReader"
```

---

### Task 2: Add `DetailTab.reply` case and tab bar entry

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift:11-20` (DetailTab enum)
- Modify: `Sources/ClaudeBoard/CardDetailView.swift:1336-1350` (tab bar Picker)
- Modify: `Sources/ClaudeBoard/CardDetailView.swift:194-220` (switch body)

**Step 1: Add the enum case**

In `DetailTab` enum (line 11):

```swift
enum DetailTab: String {
    case terminal, reply, history, prompt, description, summary
    // ...
}
```

**Step 2: Add tab bar entry**

In the Picker at line 1337, add `Reply` between Terminal and History:

```swift
Picker("", selection: $selectedTab) {
    Text("Terminal").tag(DetailTab.terminal)
    if card.link.sessionLink != nil { Text("Reply").tag(DetailTab.reply) }
    Text("History").tag(DetailTab.history)
    if card.link.promptBody != nil || card.link.sessionLink != nil {
        Text("Prompts").tag(DetailTab.prompt)
    }
    if card.link.todoistId != nil { Text("Task").tag(DetailTab.description) }
    if card.link.sessionLink != nil { Text("Summary").tag(DetailTab.summary) }
}
```

**Step 3: Add switch case placeholder**

In the content switch (line 194), add between `.terminal` and `.history`:

```swift
case .reply:
    Text("Reply tab coming soon")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
```

**Step 4: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "feat: add Reply tab enum case and tab bar entry"
```

---

### Task 3: Create ReplyTabView with WKWebView

**Files:**
- Create: `Sources/ClaudeBoard/ReplyTabView.swift`

**Step 1: Create the view**

```swift
import SwiftUI
import WebKit
import ClaudeBoardCore

struct ReplyTabView: NSViewRepresentable {
    let sessionPath: String?
    @State private var cachedTurnIndex: Int = -1

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // Transparent background
        loadReply(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadReply(into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadReply(into webView: WKWebView) {
        guard let path = sessionPath else {
            webView.loadHTMLString(Self.htmlPage(body: "<p class=\"placeholder\">No session</p>"), baseURL: nil)
            return
        }

        Task {
            do {
                guard let result = try await TranscriptReader.lastAssistantTextBlocks(from: path) else {
                    await MainActor.run {
                        webView.loadHTMLString(Self.htmlPage(body: "<p class=\"placeholder\">Waiting for reply\u{2026}</p>"), baseURL: nil)
                    }
                    return
                }

                guard result.texts.isEmpty == false else {
                    await MainActor.run {
                        webView.loadHTMLString(Self.htmlPage(body: "<p class=\"placeholder\">No text output in last reply</p>"), baseURL: nil)
                    }
                    return
                }

                let markdown = result.texts.joined(separator: "\n\n")
                let escapedMd = markdown
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "$", with: "\\$")

                let html = Self.htmlPage(body: """
                    <div id="content"></div>
                    <script>\(Self.markedJs)</script>
                    <script>
                        document.getElementById('content').innerHTML = marked.parse(`\(escapedMd)`);
                    </script>
                    """)

                await MainActor.run {
                    webView.loadHTMLString(html, baseURL: nil)
                }
            } catch {
                await MainActor.run {
                    webView.loadHTMLString(Self.htmlPage(body: "<p class=\"placeholder\">Error loading reply</p>"), baseURL: nil)
                }
            }
        }
    }

    /// Block all navigation (no network access)
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other { return .allow }  // Allow initial load
            return .cancel
        }
    }

    // MARK: - HTML Template

    static func htmlPage(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(Self.css)</style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Dracula CSS

    static let css = """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            background: #282a36;
            color: #f8f8f2;
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.6;
            padding: 20px;
        }
        .placeholder {
            color: #6272a4;
            font-style: italic;
            text-align: center;
            margin-top: 40px;
        }
        h1, h2, h3, h4, h5, h6 {
            color: #bd93f9;
            margin: 1em 0 0.5em 0;
        }
        h1 { font-size: 1.5em; }
        h2 { font-size: 1.3em; }
        h3 { font-size: 1.15em; }
        p { margin: 0.5em 0; }
        strong { color: #ffb86c; }
        em { color: #f1fa8c; }
        code {
            background: #44475a;
            padding: 2px 6px;
            border-radius: 4px;
            font-family: "SF Mono", Menlo, monospace;
            font-size: 0.9em;
        }
        pre {
            background: #44475a;
            padding: 12px 16px;
            border-radius: 6px;
            overflow-x: auto;
            margin: 0.75em 0;
        }
        pre code {
            background: none;
            padding: 0;
        }
        a { color: #8be9fd; text-decoration: none; }
        a:hover { text-decoration: underline; }
        blockquote {
            border-left: 3px solid #6272a4;
            padding-left: 12px;
            color: #6272a4;
            margin: 0.75em 0;
        }
        ul, ol {
            padding-left: 1.5em;
            margin: 0.5em 0;
        }
        li { margin: 0.25em 0; }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 0.75em 0;
            font-size: 0.95em;
        }
        thead th {
            background: #44475a;
            color: #bd93f9;
            font-weight: 600;
            text-align: left;
            padding: 8px 12px;
            border-bottom: 2px solid #6272a4;
        }
        tbody td {
            padding: 6px 12px;
            border-bottom: 1px solid #44475a;
        }
        tbody tr:nth-child(even) {
            background: rgba(68, 71, 90, 0.3);
        }
        tbody tr:hover {
            background: rgba(98, 114, 164, 0.2);
        }
        hr {
            border: none;
            border-top: 1px solid #44475a;
            margin: 1em 0;
        }
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: #282a36; }
        ::-webkit-scrollbar-thumb { background: #44475a; border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #6272a4; }
    """

    // MARK: - Marked.js (embedded)
    // This will be the minified marked.js library content.
    // Download from: https://cdn.jsdelivr.net/npm/marked/marked.min.js
    // Paste the minified content here as a string literal.
    static let markedJs = "/* PLACEHOLDER — paste marked.min.js content here */"
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/ReplyTabView.swift
git commit -m "feat: create ReplyTabView with WKWebView and Dracula CSS"
```

---

### Task 4: Embed marked.min.js

**Files:**
- Modify: `Sources/ClaudeBoard/ReplyTabView.swift` (replace `markedJs` placeholder)

**Step 1: Download marked.min.js**

```bash
curl -sL "https://cdn.jsdelivr.net/npm/marked@15.0.7/marked.min.js" -o /tmp/marked.min.js
wc -c /tmp/marked.min.js   # Should be ~40-60KB
```

**Step 2: Embed as Swift string**

Read `/tmp/marked.min.js` and replace the `markedJs` placeholder in `ReplyTabView.swift`. The content goes between the quotes of `static let markedJs = "..."`.

Escape any backslashes and double-quotes in the JS content for Swift string literal compatibility. Alternatively, use a raw string `#"..."#` if escaping is complex.

**Step 3: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/ClaudeBoard/ReplyTabView.swift
git commit -m "feat: embed marked.min.js for markdown rendering"
```

---

### Task 5: Wire ReplyTabView into CardDetailView

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`

**Step 1: Replace the placeholder switch case**

Change the `.reply` case (from Task 2) to:

```swift
case .reply:
    ReplyTabView(
        sessionPath: card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath
    )
```

**Step 2: Add onChange for reply tab refresh**

In the `.onChange(of: selectedTab)` handler (around line 244), add reply tab handling:

```swift
if selectedTab == .reply {
    // Reply tab loads on focus via its own internal Task — no action needed here
}
```

No additional wiring needed — `ReplyTabView.loadReply()` fires on `makeNSView` and `updateNSView`.

**Step 3: Build and test manually**

Run: `make run-app`
- Open a card with a session
- Click the "Reply" tab
- Verify it shows the last assistant message with rendered markdown tables
Expected: Styled markdown output in Dracula theme

**Step 4: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "feat: wire ReplyTabView into card detail panel"
```

---

### Task 6: Final build + push

**Step 1: Full build and test**

```bash
swift build && swift test
```

Expected: BUILD SUCCEEDED, all tests pass

**Step 2: Push**

```bash
git push
```
