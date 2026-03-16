# Missed Changes Reimplementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use superpowers:test-driven-development for tasks with tests.

**Goal:** Reimplement all 13 missed changes (A-M) from the lost ClaudeBoard sessions that were not included in the first reimplementation round.

**Architecture:** Elm-like unidirectional state (AppState → Action → Reducer → Effect). Pure Swift library (KanbanCodeCore) + SwiftUI app (KanbanCode). macOS 26, Swift 6.2.

**Tech Stack:** SwiftUI, AppKit, SwiftTerm, Swift Testing (`@Test`, `#expect`), SPM

**Repo:** `~/Obsidian/MyVault/Playground/Development/claudeboard`

**Build/Test:** `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build` / `swift test`

**CRITICAL RULE:** Commit AND push after every task. `git add -A && git commit -m "..." && git push`

---

### Task 1: Dracula Color Definitions

**Files:**
- Modify: `Sources/KanbanCode/ColorExtensions.swift`

**Step 1: Add Dracula color palette**

Add before `// MARK: - Project Color Environment`:

```swift
// MARK: - Dracula Theme

extension Color {
    /// Dracula background — app chrome, window background
    static let draculaBg = Color(hex: "#2B2D42")
    /// Cards, note pad, elevated surfaces
    static let draculaSurface = Color(hex: "#333654")
    /// Selected/highlighted items, code blocks
    static let draculaCurrentLine = Color(hex: "#44475A")
}
```

**Step 2: Build**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build`

**Step 3: Commit and push**

```bash
git add -A && git commit -m "feat: Dracula color palette definitions" && git push
```

---

### Task 2: Dracula Theme — Force Dark Mode + Card Backgrounds

**Files:**
- Modify: `Sources/KanbanCode/ContentView.swift`
- Modify: `Sources/KanbanCode/CardView.swift`

**Step 1: Force dark mode in ContentView**

Find `applyAppearance()` method (or where `appearanceMode` is applied). Replace ALL appearance switching logic with:

```swift
NSApp.appearance = NSAppearance(named: .darkAqua)
```

Remove the appearance toggle button from the toolbar entirely (search for `appearanceMode`). If there's a button that cycles through auto/light/dark, delete it.

**Step 2: Card backgrounds**

In `CardView.swift`, find line ~121:
```swift
.background(
    isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
    in: RoundedRectangle(cornerRadius: 8)
)
```

Replace with:
```swift
.background(
    isSelected ? Color.draculaCurrentLine : Color.draculaSurface,
    in: RoundedRectangle(cornerRadius: 8)
)
```

**Step 3: Card button capsule backgrounds**

In `CardView.swift`, find the two `.background(.ultraThinMaterial, in: Capsule())` lines (~98 and ~112). Replace both with:
```swift
.background(Color.draculaCurrentLine, in: Capsule())
```

**Step 4: Build**

Run: `swift build`

**Step 5: Commit and push**

```bash
git add -A && git commit -m "feat: Dracula theme — force dark mode + card backgrounds" && git push
```

---

### Task 3: Dracula Theme — All Surfaces

**Files:**
- Modify: `Sources/KanbanCode/ColumnView.swift`
- Modify: `Sources/KanbanCode/DragAndDrop.swift`
- Modify: `Sources/KanbanCode/BoardView.swift`
- Modify: `Sources/KanbanCode/CardDetailView.swift`
- Modify: `Sources/KanbanCode/ListBoardView.swift`
- Modify: `Sources/KanbanCode/QueuedPromptsBar.swift`

**Step 1: Replace ALL `.ultraThinMaterial` with Dracula colors**

In every file listed above, replace `.ultraThinMaterial` with `Color.draculaSurface`.

Use `replace_all: true` for each file where the Edit tool supports it.

Specific replacements:
- `.background(.ultraThinMaterial, in: RoundedRectangle(...)` → `.background(Color.draculaSurface, in: RoundedRectangle(...)`
- `.background(.ultraThinMaterial, in: Capsule())` → `.background(Color.draculaCurrentLine, in: Capsule())`
- `.background(.ultraThinMaterial.opacity(...))` → `.background(Color.draculaSurface.opacity(...))`

For `ListBoardView.swift`: also replace `Color.accentColor.opacity(0.08)` and `Color.accentColor.opacity(0.12)` with `Color.draculaCurrentLine`.

**Step 2: Build**

Run: `swift build`

**Step 3: Commit and push**

```bash
git add -A && git commit -m "feat: Dracula theme on all surfaces — replace ultraThinMaterial" && git push
```

---

### Task 4: Fix Note Pad — Move to BoardView + Dracula + maxHeight 500

**Files:**
- Modify: `Sources/KanbanCode/ContentView.swift` (remove note pad from here)
- Modify: `Sources/KanbanCode/BoardView.swift` (add note pad here)

**Step 1: Remove note pad from ContentView**

Find the note pad code block added in the previous round (search for `"Notes"` or `updateNotes`). Remove the entire `if let selectedId = store.state.selectedCardId` block that contains the TextEditor.

**Step 2: Add note pad to BoardView**

In `BoardView.swift`, add these state variables:
```swift
@State private var noteText: String = ""
@State private var noteCardId: String?
```

Add a computed property:
```swift
private var selectedCard: KanbanCodeCard? {
    guard let id = store.state.selectedCardId else { return nil }
    return store.state.cards.first { $0.id == id }
}
```

After the board `HStack` (columns + terminal), add:
```swift
if let card = selectedCard {
    notePadView(for: card)
}
```

Add the method:
```swift
@ViewBuilder
private func notePadView(for card: KanbanCodeCard) -> some View {
    VStack(spacing: 4) {
        HStack {
            Text("Notes")
                .font(.app(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.link.notes ?? "", forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .font(.app(.caption))
            .foregroundStyle(.secondary)

            Button {
                if let tmux = card.link.tmuxLink?.sessionName,
                   let notes = card.link.notes, !notes.isEmpty {
                    // Save first, then push
                    store.dispatch(.updateNotes(cardId: card.id, notes: notes))
                    Task {
                        let tmuxPath = ShellCommand.findExecutable("tmux") ?? "tmux"
                        let _ = try? await ShellCommand.run(tmuxPath, arguments: ["send-keys", "-t", tmux, notes, "Enter"])
                        await MainActor.run {
                            store.dispatch(.updateNotes(cardId: card.id, notes: nil))
                        }
                    }
                }
            } label: {
                Label("Push to Terminal", systemImage: "terminal")
            }
            .buttonStyle(.plain)
            .font(.app(.caption))
            .foregroundStyle(.secondary)
            .disabled(card.link.tmuxLink == nil || (card.link.notes ?? "").isEmpty)
        }
        .padding(.horizontal, 8)

        TextEditor(text: Binding(
            get: { store.state.links[card.id]?.notes ?? "" },
            set: { store.dispatch(.updateNotes(cardId: card.id, notes: $0.isEmpty ? nil : $0)) }
        ))
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(4)
        .background(Color.draculaSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxHeight: 500)
    }
    .padding(.horizontal)
    .padding(.bottom, 8)
}
```

Also add `.fixedSize(horizontal: true, vertical: false)` on the left VStack (the one containing the columns) to prevent horizontal resizing from the note pad.

**Step 3: Build**

Run: `swift build`

**Step 4: Commit and push**

```bash
git add -A && git commit -m "fix: note pad in BoardView with Dracula styling + maxHeight 500" && git push
```

---

### Task 5: Fix Summary Tab — Intent Prompt + Markdown + Auto-Archive

**Files:**
- Modify: `Sources/KanbanCode/CardDetailView.swift`
- Modify: `Sources/KanbanCodeCore/UseCases/AutoCleanup.swift`
- Modify: `Sources/KanbanCodeCore/UseCases/AssignColumn.swift`

**Step 1: Update summary prompt to intent-focused**

Find `loadSummary()` in CardDetailView.swift. Replace the prompt string with:

```swift
let prompt = """
[CB-SUMMARY] Analyze this Claude Code session. The user's original goal was the first message. Provide:

## Goal
What the user wanted to accomplish (1 sentence)

## Journey
Key steps taken, decisions made, problems encountered (3-5 bullets)

## Current State
What's been accomplished so far

## Next Steps
What remains to be done (if anything)

Conversation:
\(transcript)
"""
```

**Step 2: Add Markdown rendering to summary display**

Find where `summaryText` is displayed (the `Text(summary)` in summaryTabView). Replace with:

```swift
if let attributed = try? AttributedString(markdown: summary) {
    Text(attributed)
        .font(.app(.body))
        .textSelection(.enabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
} else {
    Text(summary)
        .font(.app(.body))
        .textSelection(.enabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
}
```

**Step 3: Auto-archive [CB-SUMMARY] sessions in AutoCleanup**

In `AutoCleanup.swift`, in the scheduled-task loop, add a check for summary sessions:

```swift
if link.column == .waiting || link.column == .inProgress {
    let text = [link.name, link.promptBody]
        .compactMap { $0 }
        .first { !$0.isEmpty && ($0.hasPrefix("<scheduled-task name=") || $0.hasPrefix("[CB-SUMMARY]")) }
    if text != nil {
        var updated = link
        updated.column = .done
        return updated
    }
}
```

**Step 4: Route [CB-SUMMARY] to .done in AssignColumn**

In `AssignColumn.swift`, before the todoist check, add:

```swift
// Summary sessions → done
if let prompt = link.promptBody, prompt.hasPrefix("[CB-SUMMARY]") {
    return .done
}
```

**Step 5: Build and test**

Run: `swift build && swift test`

**Step 6: Commit and push**

```bash
git add -A && git commit -m "fix: summary tab — intent prompt, Markdown, auto-archive [CB-SUMMARY]" && git push
```

---

### Task 6: TerminalOverlayState + Tests

**Files:**
- Create: `Sources/KanbanCodeCore/UseCases/TerminalOverlayState.swift`
- Create: `Tests/KanbanCodeCoreTests/TerminalOverlayTests.swift`

**Step 1: Write failing tests**

Create `Tests/KanbanCodeCoreTests/TerminalOverlayTests.swift`:

```swift
import Testing
@testable import KanbanCodeCore

struct TerminalOverlayTests {
    @Test("Tracks sessions and active session")
    func tracksSessions() {
        var state = TerminalOverlayState()
        let changed = state.update(sessions: ["s1", "s2"], active: "s1", frame: .zero)
        #expect(changed)
        #expect(state.sessions == ["s1", "s2"])
        #expect(state.activeSession == "s1")
    }

    @Test("Detects no change when state unchanged")
    func detectsNoChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1"], active: "s1", frame: .zero)
        let changed = state.update(sessions: ["s1"], active: "s1", frame: .zero)
        #expect(!changed)
    }

    @Test("Detects session change")
    func detectsSessionChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1"], active: "s1", frame: .zero)
        let changed = state.update(sessions: ["s1", "s2"], active: "s1", frame: .zero)
        #expect(changed)
    }

    @Test("Detects active session change")
    func detectsActiveChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1", "s2"], active: "s1", frame: .zero)
        let changed = state.update(sessions: ["s1", "s2"], active: "s2", frame: .zero)
        #expect(changed)
    }

    @Test("Detects frame change")
    func detectsFrameChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1"], active: "s1", frame: .init(x: 0, y: 0, width: 100, height: 100))
        let changed = state.update(sessions: ["s1"], active: "s1", frame: .init(x: 0, y: 0, width: 200, height: 100))
        #expect(changed)
    }
}
```

**Step 2: Run tests — expect failure**

Run: `swift test --filter TerminalOverlay`

**Step 3: Implement**

Create `Sources/KanbanCodeCore/UseCases/TerminalOverlayState.swift`:

```swift
import Foundation

/// Pure state tracker for terminal overlay. Detects changes so the AppKit layer
/// only redraws when needed. No AppKit dependency — testable in Core.
public struct TerminalOverlayState: Sendable {
    public var sessions: [String] = []
    public var activeSession: String?
    public var frame: CGRect = .zero

    public init() {}

    /// Update state. Returns true if anything changed.
    @discardableResult
    public mutating func update(sessions: [String], active: String?, frame: CGRect) -> Bool {
        let changed = self.sessions != sessions
            || self.activeSession != active
            || self.frame != frame
        self.sessions = sessions
        self.activeSession = active
        self.frame = frame
        return changed
    }
}
```

**Step 4: Run tests — expect pass**

Run: `swift test --filter TerminalOverlay`

**Step 5: Commit and push**

```bash
git add -A && git commit -m "feat: TerminalOverlayState with change detection + tests" && git push
```

---

### Task 7: Terminal Stability — Singleton Container + .id() + Delayed Unhide

**Files:**
- Modify: `Sources/KanbanCode/TerminalRepresentable.swift`
- Modify: `Sources/KanbanCode/BoardView.swift`

**Step 1: Singleton TerminalContainerNSView**

In `TerminalRepresentable.swift`, find `TerminalCache`. Add:

```swift
/// Singleton container — never destroyed by SwiftUI.
var cachedContainer: TerminalContainerNSView?
```

In `TerminalContainerView` (the NSViewRepresentable), change `makeNSView` to return the cached singleton:

```swift
func makeNSView(context: Context) -> TerminalContainerNSView {
    if let cached = TerminalCache.shared.cachedContainer {
        return cached
    }
    let container = TerminalContainerNSView()
    TerminalCache.shared.cachedContainer = container
    return container
}
```

Make `dismantleNSView` a no-op:
```swift
static func dismantleNSView(_ nsView: TerminalContainerNSView, coordinator: ()) {
    // No-op: singleton container survives SwiftUI teardown
}
```

**Step 2: Delayed unhide on session switch**

In `TerminalContainerNSView`, find where terminals are shown/hidden on session switch. Add a 50ms delay before unhiding:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
    terminal.isHidden = false
}
```

**Step 3: .id() on terminal panel in BoardView**

In `BoardView.swift`, find where the terminal content is rendered. Add `.id(store.state.selectedCardId ?? "none")` on the terminal container view to give SwiftUI stable structural identity.

**Step 4: Build**

Run: `swift build`

**Step 5: Commit and push**

```bash
git add -A && git commit -m "fix: singleton terminal container + delayed unhide + stable .id()" && git push
```

---

### Task 8: Quick Launch Bar

**Files:**
- Modify: `Sources/KanbanCode/BoardView.swift`
- Modify: `Sources/KanbanCode/ContentView.swift`

**Step 1: Add quick launch bar to BoardView**

Add state:
```swift
@State private var quickLaunchText: String = ""
```

Add callback:
```swift
var onQuickLaunch: (String) -> Void = { _ in }
```

Wrap the terminal content in a VStack. Above it, add:
```swift
HStack(spacing: 8) {
    TextField("Quick launch...", text: $quickLaunchText)
        .textFieldStyle(.plain)
        .font(.system(.body, design: .monospaced))
        .padding(6)
        .background(Color.draculaSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onSubmit { submitQuickLaunch() }

    Button(action: submitQuickLaunch) {
        Image(systemName: "play.fill")
            .foregroundStyle(.green)
    }
    .buttonStyle(.plain)
    .disabled(quickLaunchText.trimmingCharacters(in: .whitespaces).isEmpty)
}
.padding(.horizontal, 8)
.padding(.top, 4)
```

Add the method:
```swift
private func submitQuickLaunch() {
    let text = quickLaunchText.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    onQuickLaunch(text)
    quickLaunchText = ""
}
```

**Step 2: Wire in ContentView**

Find where `BoardView` is instantiated. Add:
```swift
onQuickLaunch: { prompt in
    let link = Link(name: String(prompt.prefix(80)), column: .backlog, source: .manual, promptBody: prompt)
    store.dispatch(.createManualTask(link))
    store.dispatch(.launchCard(cardId: link.id, prompt: prompt, projectPath: NSHomeDirectory(), worktreeName: nil, runRemotely: false, commandOverride: nil))
}
```

**Step 3: Build**

Run: `swift build`

**Step 4: Commit and push**

```bash
git add -A && git commit -m "feat: quick launch bar above terminal panel" && git push
```

---

### Task 9: Rename Button in Detail Header

**Files:**
- Modify: `Sources/KanbanCode/CardDetailView.swift`

**Step 1: Add pencil icon next to card title**

Find the card title display in CardDetailView (search for `card.displayTitle` in the header area). After the title Text, add:

```swift
Button(action: { showRenameSheet = true }) {
    Image(systemName: "pencil.circle.fill")
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
}
.buttonStyle(.plain)
.help("Rename")
```

**Step 2: Build**

Run: `swift build`

**Step 3: Commit and push**

```bash
git add -A && git commit -m "feat: rename pencil button in detail header" && git push
```

---

### Task 10: Strip Git Integration + Columns Clipped

**Files:**
- Delete: `Sources/KanbanCode/AddLinkPopover.swift`
- Modify: `Sources/KanbanCode/CardDetailView.swift` (remove onAddBranch)
- Modify: `Sources/KanbanCode/ContentView.swift` (remove onAddBranch wiring)
- Modify: `Sources/KanbanCode/BoardView.swift` (add .clipped())

**Step 1: Delete AddLinkPopover.swift**

```bash
rm Sources/KanbanCode/AddLinkPopover.swift
```

**Step 2: Remove onAddBranch references**

In `CardDetailView.swift`: remove `var onAddBranch: (String) -> Void = { _ in }` property and any "Add Link" button that references it.

In `ContentView.swift`: remove any `onAddBranch:` parameter passed to CardDetailView.

**Step 3: Add .clipped() to columns**

In `BoardView.swift`, find the board HStack with columns. On the VStack or container that wraps the columns (not the terminal), add `.clipped()` after any `.frame(maxHeight:)` to prevent card overflow.

**Step 4: Build**

Run: `swift build`

**Step 5: Commit and push**

```bash
git add -A && git commit -m "chore: strip git integration + clip columns to prevent overflow" && git push
```

---

### Task 11: AnyView → Generic Type Parameter

**Files:**
- Modify: `Sources/KanbanCode/BoardView.swift`
- Modify: `Sources/KanbanCode/ContentView.swift`

**Step 1: Change BoardView to generic**

In `BoardView.swift`, change:
```swift
struct BoardView: View {
    ...
    var terminalContent: AnyView? = nil
```

To:
```swift
struct BoardView<TerminalContent: View>: View {
    ...
    var terminalContent: TerminalContent?
```

Update the body to use `terminalContent` directly instead of through `AnyView`.

**Step 2: Update ContentView**

Where ContentView creates `BoardView`, remove `AnyView(...)` wrapping around the terminal content. Pass the concrete view directly.

**Step 3: Build**

Run: `swift build`

**Step 4: Commit and push**

```bash
git add -A && git commit -m "refactor: BoardView generic type parameter replaces AnyView" && git push
```

---

### Task 12: Prompt Timeline — Dracula Background on Original Prompt

**Files:**
- Modify: `Sources/KanbanCode/CardDetailView.swift`

**Step 1: Fix original prompt highlight**

In the `promptTimelineView`, find the original prompt section background:
```swift
.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
```

Replace with:
```swift
.background(Color.draculaCurrentLine)
```

**Step 2: Build**

Run: `swift build`

**Step 3: Commit and push**

```bash
git add -A && git commit -m "fix: Dracula background on original prompt in timeline" && git push
```

---

### Task 13: Module Rename — KanbanCode → ClaudeBoard

This is the largest task. It renames ALL Swift modules, directories, Package.swift targets, and imports.

**Files:**
- Rename: `Sources/KanbanCode/` → `Sources/ClaudeBoard/`
- Rename: `Sources/KanbanCodeCore/` → `Sources/ClaudeBoardCore/`
- Rename: `Tests/KanbanCodeCoreTests/` → `Tests/ClaudeBoardCoreTests/`
- Rename: `Tests/KanbanCodeTests/` → `Tests/ClaudeBoardTests/`
- Modify: `Package.swift`
- Modify: ALL `.swift` files (import statements, type references)

**Step 1: Rename directories**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
mv Sources/KanbanCode Sources/ClaudeBoard
mv Sources/KanbanCodeCore Sources/ClaudeBoardCore
mv Tests/KanbanCodeCoreTests Tests/ClaudeBoardCoreTests
mv Tests/KanbanCodeTests Tests/ClaudeBoardTests
```

**Step 2: Update Package.swift**

Replace entire contents with:
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeBoard",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "ClaudeBoard", targets: ["ClaudeBoard"]),
        .executable(name: "kanban-code-active-session", targets: ["KanbanCodeActiveSession"]),
        .library(name: "ClaudeBoardCore", targets: ["ClaudeBoardCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeBoard",
            dependencies: ["ClaudeBoardCore", "SwiftTerm", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources/ClaudeBoard",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "KanbanCodeActiveSession",
            path: "Sources/KanbanCodeActiveSession"
        ),
        .target(
            name: "ClaudeBoardCore",
            path: "Sources/ClaudeBoardCore"
        ),
        .testTarget(
            name: "ClaudeBoardCoreTests",
            dependencies: ["ClaudeBoardCore"],
            path: "Tests/ClaudeBoardCoreTests"
        ),
        .testTarget(
            name: "ClaudeBoardTests",
            dependencies: ["ClaudeBoard", "ClaudeBoardCore"],
            path: "Tests/ClaudeBoardTests"
        ),
    ]
)
```

**Step 3: Rename all imports and type references**

Use `sed` or find-and-replace across ALL .swift files:

```bash
# In Sources/ClaudeBoard/ — change imports
find Sources/ClaudeBoard -name "*.swift" -exec sed -i '' 's/import KanbanCodeCore/import ClaudeBoardCore/g' {} +

# In Tests/ — change imports
find Tests -name "*.swift" -exec sed -i '' 's/import KanbanCodeCore/import ClaudeBoardCore/g' {} +
find Tests -name "*.swift" -exec sed -i '' 's/@testable import KanbanCodeCore/@testable import ClaudeBoardCore/g' {} +
find Tests -name "*.swift" -exec sed -i '' 's/@testable import KanbanCode$/@testable import ClaudeBoard/g' {} +

# Rename types across ALL files
find Sources Tests -name "*.swift" -exec sed -i '' 's/KanbanCodeCard/ClaudeBoardCard/g' {} +
find Sources Tests -name "*.swift" -exec sed -i '' 's/KanbanCodeColumn/ClaudeBoardColumn/g' {} +
find Sources Tests -name "*.swift" -exec sed -i '' 's/KanbanCodeLog/ClaudeBoardLog/g' {} +
find Sources Tests -name "*.swift" -exec sed -i '' 's/KanbanCodeApp/ClaudeBoardApp/g' {} +

# Rename the KanbanCodeCore.swift module file
mv Sources/ClaudeBoardCore/KanbanCodeCore.swift Sources/ClaudeBoardCore/ClaudeBoardCore.swift
```

**Step 4: Fix any remaining references**

```bash
# Check for any remaining KanbanCode references (except KanbanCodeActiveSession which stays)
grep -r "KanbanCode" Sources/ClaudeBoard Sources/ClaudeBoardCore Tests --include="*.swift" | grep -v "KanbanCodeActiveSession" | grep -v ".build/"
```

Fix any remaining references manually.

**Step 5: Update Notification.Name constants**

In `App.swift`, the notification names like `.kanbanCodeHookEvent` should be renamed to `.claudeBoardHookEvent` etc. Search and replace:

```bash
find Sources Tests -name "*.swift" -exec sed -i '' 's/kanbanCode/claudeBoard/g' {} +
find Sources Tests -name "*.swift" -exec sed -i '' 's/kanbanSelect/claudeBoardSelect/g' {} +
find Sources Tests -name "*.swift" -exec sed -i '' 's/kanbanClose/claudeBoardClose/g' {} +
```

**Step 6: Update Makefile**

In `Makefile`, update `BUNDLE_NAME`, `BUNDLE_ID`, binary name, and paths:
- `BUNDLE_NAME = ClaudeBoard.app`
- `BUNDLE_ID = com.ciro.claudeboard`
- Binary: `ClaudeBoard` instead of `KanbanCode`

**Step 7: Build and test**

Run: `swift build && swift test`

Fix any compilation errors. This will likely need several iterations.

**Step 8: Commit and push**

```bash
git add -A && git commit -m "refactor: rename KanbanCode → ClaudeBoard across entire codebase" && git push
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Dracula color definitions | 1 |
| 2 | Dracula — dark mode + card backgrounds | 2 |
| 3 | Dracula — all surfaces | 6 |
| 4 | Fix note pad (BoardView + Dracula + 500px) | 2 |
| 5 | Fix summary tab (intent prompt + Markdown + auto-archive) | 3 |
| 6 | TerminalOverlayState + tests | 2 new |
| 7 | Terminal stability (singleton + delay + .id) | 2 |
| 8 | Quick launch bar | 2 |
| 9 | Rename button in detail header | 1 |
| 10 | Strip git integration + clipped columns | 4 |
| 11 | AnyView → generic type parameter | 2 |
| 12 | Prompt timeline Dracula background | 1 |
| 13 | Module rename KanbanCode → ClaudeBoard | ALL files |

Total: 13 tasks. Commit and push after each one.
