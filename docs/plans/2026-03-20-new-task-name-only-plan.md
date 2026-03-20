# New Task Dialog — Name Only Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Dialog text becomes card name only — Claude launches with no initial prompt.

**Architecture:** Three surgical changes: (1) dialog placeholder text, (2) `createManualTask` sets `promptBody: nil`, (3) `startCard` only sends a prompt when `promptBody` exists. The existing `if !prompt.isEmpty` guard in `executeLaunch` handles the rest.

**Tech Stack:** Swift 6, SwiftUI, swift-testing

---

### Task 1: Add test — PromptBuilder returns empty when promptBody is nil and name is set

This validates that we can distinguish "has a name but no prompt" from "has a prompt."
The current `emptyCard` test already covers nil name + nil body, but we need the case
where name IS set and promptBody IS nil.

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/PromptBuilderTests.swift`

**Step 1: Write the failing test**

Add after the existing `emptyCard` test:

```swift
@Test("Name-only card returns name from buildPrompt — caller decides whether to send")
func nameOnlyCardReturnsName() {
    let link = Link(name: "My Task", source: .manual)
    let prompt = PromptBuilder.buildPrompt(card: link)
    // PromptBuilder returns name as fallback — startCard must check promptBody separately
    #expect(prompt == "My Task")
}
```

**Step 2: Run test to verify it passes**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter PromptBuilderTests/nameOnlyCardReturnsName 2>&1 | tail -5`

Expected: PASS — this confirms the current PromptBuilder behavior (falls back to name).
We're documenting existing behavior so the next task's change to `startCard` is safe.

**Step 3: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/PromptBuilderTests.swift
git commit -m "test: document PromptBuilder name-only fallback behavior"
git push
```

---

### Task 2: Change `createManualTask` to set `promptBody: nil`

The dialog text becomes the card name only. No prompt is stored.

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift:1449-1477`

**Step 1: Edit `createManualTask`**

Change the Link creation at line 1462-1469 from:

```swift
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: startImmediately ? .inProgress : .backlog,
            source: .manual,
            promptBody: trimmed,
            promptImagePaths: imagePaths
        )
```

to:

```swift
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: startImmediately ? .inProgress : .backlog,
            source: .manual,
            promptBody: nil,
            promptImagePaths: imagePaths
        )
```

**Step 2: Build to verify it compiles**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`

Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "feat: createManualTask sets promptBody to nil (name-only cards)"
git push
```

---

### Task 3: Change `startCard` to not send name as prompt

Currently `startCard` (line 1541-1557) calls `PromptBuilder.buildPrompt` which
falls back to `link.name` when `promptBody` is nil, then has a second fallback at
line 1550-1551. Both paths would send the card name as a prompt — we need to
prevent that.

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift:1541-1557`

**Step 1: Edit `startCard`**

Replace the prompt-building logic (lines 1549-1552):

```swift
            var prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)
            if prompt.isEmpty {
                prompt = card.link.promptBody ?? card.link.name ?? ""
            }
```

with:

```swift
            let prompt: String
            if card.link.promptBody != nil {
                prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)
            } else {
                prompt = ""
            }
```

This way: cards with a `promptBody` still get template wrapping via PromptBuilder.
Cards with nil `promptBody` (name-only) produce an empty prompt, so `executeLaunch`
skips `sendPrompt` via the existing `if !prompt.isEmpty` guard at line 1596.

**Step 2: Build to verify it compiles**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`

Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "feat: startCard sends no prompt when promptBody is nil"
git push
```

---

### Task 4: Update dialog placeholder text

Cosmetic — makes it clear the field is for naming, not prompting.

**Files:**
- Modify: `Sources/ClaudeBoard/NewTaskDialog.swift:24`

**Step 1: Change placeholder**

At line 24, change:

```swift
            TextField("What needs to be done?", text: $prompt)
```

to:

```swift
            TextField("Card name", text: $prompt)
```

Also rename the `@State` variable for clarity. At line 11, change:

```swift
    @State private var prompt = ""
```

to:

```swift
    @State private var cardName = ""
```

Then update all references in the file:
- Line 24: `text: $cardName`
- Line 49: `cardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`
- Line 71: `!cardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`
- Line 74: `onCreate(cardName, proj, nil, true, [])`

**Step 2: Build to verify it compiles**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`

Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/NewTaskDialog.swift
git commit -m "feat: rename dialog field from prompt to card name"
git push
```

---

### Task 5: Run full test suite

**Step 1: Run all tests**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -20`

Expected: All tests pass. No existing tests should break because:
- PromptBuilder behavior unchanged
- Reducer tests use `makeLink()` helper (unaffected)
- No existing tests assert `promptBody` is non-nil from dialog flow

**Step 2: Deploy and smoke test**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && make deploy`

Manual check: Click "+" to create a new task → type a name → card appears → Claude
opens in tmux at `>` prompt with no message sent.
