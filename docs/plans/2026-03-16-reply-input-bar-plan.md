# Reply Tab Input Bar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a text input bar to the Reply tab that sends messages to tmux, auto-refreshes on new replies, and shows a status indicator for whether Claude is still responding.

**Architecture:** New `ReplyInputBar` SwiftUI view composed below the existing `ReplyTabView` WKWebView in `CardDetailView`. Sends text via a new `onSendReplyText` callback (wired to `TmuxAdapter.sendPrompt` in ContentView). Auto-refresh reuses the existing `.claudeBoardHistoryChanged` file watcher notification. Status indicator checks for the presence of the prompt character (`❯`) in the tmux pane output to determine idle vs working.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSTextView for key interception)

---

### Task 1: Create ReplyInputBar view

**Files:**
- Create: `Sources/ClaudeBoard/ReplyInputBar.swift`

**Step 1: Create the view with Dracula styling**

```swift
import SwiftUI

struct ReplyInputBar: View {
    @State private var inputText = ""
    @State private var sentFlash = false
    var onSend: (String) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Type a message...")
                        .foregroundStyle(Color(hex: 0x6272A4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .scrollContentBackground(.hidden)
                    .font(.app(size: 13))
                    .foregroundStyle(Color(hex: 0xF8F8F2))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minHeight: 60, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(Color(hex: 0x44475A))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(sentFlash ? Color.green.opacity(0.8) : Color(hex: 0x6272A4), lineWidth: 1)
            )

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color(hex: 0x6272A4) : Color(hex: 0xBD93F9)
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        inputText = ""
        sentFlash = true
        withAnimation(.easeOut(duration: 1.0)) {
            sentFlash = false
        }
    }
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/ReplyInputBar.swift
git commit -m "feat: create ReplyInputBar view with Dracula styling"
```

---

### Task 2: Add Enter-to-send key interception

**Files:**
- Modify: `Sources/ClaudeBoard/ReplyInputBar.swift`

**Step 1: Add key interception**

SwiftUI `TextEditor` doesn't support intercepting Enter. Wrap with an `.onKeyPress` modifier (macOS 26):

```swift
// Add to the TextEditor, after .fixedSize:
.onKeyPress(.return, phases: .down) { keyPress in
    if keyPress.modifiers.contains(.shift) {
        return .ignored // Let Shift+Enter insert newline
    }
    send()
    return .handled
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/ReplyInputBar.swift
git commit -m "feat: Enter to send, Shift+Enter for newline in ReplyInputBar"
```

---

### Task 3: Wire ReplyInputBar into CardDetailView

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`

**Step 1: Add onSendReplyText callback**

In the CardDetailView property list (around line 78, after `onUpdatePrompt`):

```swift
var onSendReplyText: (String) -> Void = { _ in }
```

**Step 2: Add ReplyInputBar below the ReplyTabView in the switch case**

Change the `.reply` case (around line 197):

```swift
case .reply:
    VStack(spacing: 0) {
        ReplyTabView(
            sessionPath: card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath
        )
        if card.link.tmuxLink != nil {
            Divider()
            ReplyInputBar(onSend: { text in
                onSendReplyText(text)
            })
        }
    }
```

**Step 3: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED — may need to add the callback in ContentView's CardDetailView initializer.

**Step 4: Wire in ContentView**

Find where `CardDetailView` is constructed in `ContentView.swift` and add:

```swift
onSendReplyText: { text in
    guard let tmuxName = card.link.tmuxLink?.sessionName else { return }
    Task {
        try? await tmuxAdapter.sendPrompt(to: tmuxName, text: text)
    }
},
```

**Step 5: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift Sources/ClaudeBoard/ContentView.swift
git commit -m "feat: wire ReplyInputBar into card detail panel"
```

---

### Task 4: Add auto-refresh on reply tab when transcript changes

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`

**Step 1: Extend the history watcher to also cover the reply tab**

In the `onChange(of: selectedTab)` handler (around line 248), change:

```swift
if selectedTab == .history {
    Task { await loadHistory() }
    startHistoryWatcher()
} else {
    stopHistoryWatcher()
}
```

To:

```swift
if selectedTab == .history || selectedTab == .reply {
    if selectedTab == .history {
        Task { await loadHistory() }
    }
    startHistoryWatcher()
} else {
    stopHistoryWatcher()
}
```

**Step 2: Handle the notification for the reply tab**

In the `.onReceive(NotificationCenter.default.publisher(for: .claudeBoardHistoryChanged))` handler (around line 271), change:

```swift
guard selectedTab == .history else { return }
```

To:

```swift
guard selectedTab == .history || selectedTab == .reply else { return }
```

And add reply-specific refresh below the existing history reload:

```swift
if selectedTab == .reply {
    // Force ReplyTabView to re-read by bumping a refresh counter
    replyRefreshId += 1
}
```

**Step 3: Add the refresh state and wire it**

Add a new `@State` property near the other state vars:

```swift
@State private var replyRefreshId: Int = 0
```

Then update the `.reply` case to use it as an `.id()` modifier on ReplyTabView, so SwiftUI recreates it:

```swift
case .reply:
    VStack(spacing: 0) {
        ReplyTabView(
            sessionPath: card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath
        )
        .id(replyRefreshId)
        if card.link.tmuxLink != nil {
            Divider()
            ReplyInputBar(onSend: { text in
                onSendReplyText(text)
            })
        }
    }
```

**Step 4: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "feat: auto-refresh Reply tab on transcript changes"
```

---

### Task 5: Add status indicator (idle/working)

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`
- Modify: `Sources/ClaudeBoard/ReplyInputBar.swift`

**Step 1: Add isWorking state to CardDetailView**

Add state:

```swift
@State private var replyIsWorking = false
```

**Step 2: Poll tmux pane for prompt character when reply tab is active**

Add a polling task that checks for the prompt character (`❯` for Claude) in the tmux pane output. Start it when reply tab is selected, stop when leaving.

In the `startHistoryWatcher` section for reply tab, add:

```swift
if selectedTab == .reply {
    startReplyStatusPoller()
}
```

Add the poller method:

```swift
private func startReplyStatusPoller() {
    replyStatusPollTask?.cancel()
    replyStatusPollTask = Task { @MainActor in
        while !Task.isCancelled && selectedTab == .reply {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, selectedTab == .reply else { break }
            await checkReplyStatus()
        }
    }
}

private func checkReplyStatus() async {
    guard let tmuxName = card.link.tmuxLink?.sessionName else {
        replyIsWorking = false
        return
    }
    do {
        let pane = try await TmuxAdapter.shared.capturePane(sessionName: tmuxName)
        let lastLine = pane.split(separator: "\n").last.map(String.init) ?? ""
        let promptChar = card.link.effectiveAssistant.promptCharacter
        replyIsWorking = !lastLine.contains(promptChar)
    } catch {
        replyIsWorking = false
    }
}
```

Add state for the poll task:

```swift
@State private var replyStatusPollTask: Task<Void, Never>?
```

Stop it when leaving reply tab (in stopHistoryWatcher or onChange):

```swift
replyStatusPollTask?.cancel()
replyStatusPollTask = nil
```

**Step 3: Pass isWorking to ReplyInputBar**

Update ReplyInputBar to accept and display the status:

```swift
var isWorking: Bool = false
```

Add above the input area in ReplyInputBar's body:

```swift
if isWorking {
    HStack(spacing: 6) {
        ProgressView()
            .controlSize(.small)
            .tint(Color(hex: 0xBD93F9))
        Text("Claude is responding...")
            .font(.app(.caption))
            .foregroundStyle(Color(hex: 0x6272A4))
        Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 6)
}
```

Wire in CardDetailView:

```swift
ReplyInputBar(isWorking: replyIsWorking, onSend: { text in
    onSendReplyText(text)
})
```

**Step 4: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift Sources/ClaudeBoard/ReplyInputBar.swift
git commit -m "feat: add working/idle status indicator to Reply tab"
```

---

### Task 6: Handle TmuxAdapter.shared access

**Files:**
- Check: `Sources/ClaudeBoardCore/Adapters/Tmux/TmuxAdapter.swift`

The status poller needs `TmuxAdapter` access from CardDetailView. Check if `TmuxAdapter.shared` exists or if it needs to go through a callback like the send does.

If no shared instance exists, add a `onCapturePane` callback instead:

```swift
// In CardDetailView:
var onCapturePane: () async -> String? = { nil }
```

Wire in ContentView:

```swift
onCapturePane: {
    guard let tmuxName = card.link.tmuxLink?.sessionName else { return nil }
    return try? await tmuxAdapter.capturePane(sessionName: tmuxName)
},
```

**Step 1: Check and implement the appropriate access pattern**

**Step 2: Build and test**

Run: `swift build && swift test`
Expected: BUILD SUCCEEDED, all tests pass

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift Sources/ClaudeBoard/ContentView.swift
git commit -m "feat: wire tmux pane capture for reply status polling"
```

---

### Task 7: Final build + push

**Step 1: Full build and test**

```bash
swift build && swift test
```

Expected: BUILD SUCCEEDED, all tests pass

**Step 2: Deploy and test manually**

```bash
make app && pkill -f ClaudeBoard; sleep 1; rm -rf /Applications/ClaudeBoard.app && cp -R build/ClaudeBoard.app /Applications/ClaudeBoard.app && open /Applications/ClaudeBoard.app
```

- Open a card with an active session
- Click the Reply tab
- Type a message and press Enter
- Verify it appears in the terminal
- Verify the "Claude is responding..." indicator shows
- Verify the reply auto-refreshes when Claude finishes

**Step 3: Push**

```bash
git push
```
