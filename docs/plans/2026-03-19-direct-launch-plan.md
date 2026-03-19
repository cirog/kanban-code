# Direct Launch Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove the LaunchConfirmationDialog so Play, Resume, and Create Task all execute immediately without a confirmation popup.

**Architecture:** Pure view-layer changes. Remove the dialog sheet, rewire `startCard()` and `resumeCard()` to call execution functions directly, and make NewTaskDialog auto-start. All changes are in the SwiftUI app target (`Sources/ClaudeBoard/`).

**Tech Stack:** Swift 6.2, SwiftUI, macOS 26

---

### Task 1: Verify baseline compiles and tests pass

**Files:** None (verification only)

**Step 1: Build the project**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 2: Run existing tests**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -10`
Expected: All tests pass

---

### Task 2: Add `@AppStorage` for `dangerouslySkipPermissions` to ContentView

The `dangerouslySkipPermissions` preference currently only lives in `LaunchConfirmationDialog`. Before we delete it, we need it accessible in `ContentView` where `startCard()` and `resumeCard()` live.

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift:48` (near other `@AppStorage` declarations)

**Step 1: Add the AppStorage property**

In `ContentView`, near line 48 (after `@AppStorage("killTmuxOnQuit")`), add:

```swift
@AppStorage("dangerouslySkipPermissions") private var dangerouslySkipPermissions = true
```

**Step 2: Build to verify**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "refactor: add dangerouslySkipPermissions AppStorage to ContentView"
git push
```

---

### Task 3: Rewire `startCard()` to call `executeLaunch()` directly

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift:1593-1612` (`startCard` method)

**Step 1: Replace `startCard()` implementation**

Replace the current `startCard()` (lines 1593-1612) which builds a `LaunchConfig` and sets `self.launchConfig`, with a version that calls `executeLaunch()` directly:

```swift
private func startCard(cardId: String) {
    guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
    let effectivePath = card.link.projectPath ?? NSHomeDirectory()
    let assistant = card.link.effectiveAssistant

    Task {
        let settings = try? await settingsStore.read()
        let project = settings?.projects.first(where: { $0.path == effectivePath })
        var prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)
        if prompt.isEmpty {
            prompt = card.link.promptBody ?? card.link.name ?? ""
        }

        let imageAttachments: [Any] = (card.link.promptImagePaths ?? []).compactMap { ImageAttachment.fromPath($0) }
        executeLaunch(cardId: cardId, prompt: prompt, projectPath: effectivePath, skipPermissions: dangerouslySkipPermissions, images: imageAttachments, assistant: assistant)
    }
}
```

**Step 2: Build to verify**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "feat: startCard calls executeLaunch directly, skipping confirmation dialog"
git push
```

---

### Task 4: Rewire `resumeCard()` to call `executeResume()` directly

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift:1810-1828` (`resumeCard` method)

**Step 1: Replace `resumeCard()` implementation**

Replace the current `resumeCard()` which builds a `LaunchConfig` and sets `self.launchConfig`, with a version that calls `executeResume()` directly:

```swift
private func resumeCard(cardId: String) {
    guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }

    // Clear stale terminal so TerminalCache creates a fresh one for the new tmux session
    if let oldTmux = card.link.tmuxLink?.sessionName {
        TerminalCache.shared.remove(oldTmux)
    }

    executeResume(cardId: cardId, skipPermissions: dangerouslySkipPermissions, commandOverride: nil, assistant: card.link.effectiveAssistant)
}
```

**Step 2: Build to verify**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "feat: resumeCard calls executeResume directly, skipping confirmation dialog"
git push
```

---

### Task 5: Make NewTaskDialog auto-start

**Files:**
- Modify: `Sources/ClaudeBoard/NewTaskDialog.swift:74`

**Step 1: Change `startImmediately` from `false` to `true`**

In `submitForm()`, line 74, change:

```swift
// Before:
onCreate(prompt, proj, nil, false, [])

// After:
onCreate(prompt, proj, nil, true, [])
```

**Step 2: Build to verify**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoard/NewTaskDialog.swift
git commit -m "feat: NewTaskDialog auto-starts card after creation"
git push
```

---

### Task 6: Remove `LaunchConfig`, `launchConfig` state, and the `.sheet` block

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift`

**Step 1: Delete the `LaunchConfig` struct (lines 5-34)**

Remove the entire `LaunchConfig` struct and its doc comment at the top of the file.

**Step 2: Delete `@State private var launchConfig: LaunchConfig?` (line 55)**

Remove the property declaration.

**Step 3: Delete `@State private var editingQueuedPromptId: String?` only if unused**

Check first — it may be used elsewhere. Only remove if it was solely for the dialog.

**Step 4: Delete the `.sheet(item: $launchConfig)` block (lines 454-474)**

Remove the entire sheet modifier that presents `LaunchConfirmationDialog`.

**Step 5: Build to verify**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 6: Run tests to verify nothing broke**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 7: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "refactor: remove LaunchConfig and launch confirmation sheet"
git push
```

---

### Task 7: Delete `LaunchConfirmationDialog.swift`

**Files:**
- Delete: `Sources/ClaudeBoard/LaunchConfirmationDialog.swift`

**Step 1: Delete the file**

```bash
rm Sources/ClaudeBoard/LaunchConfirmationDialog.swift
```

**Step 2: Build to verify**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Run full test suite**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```bash
cd ~/Obsidian/MyVault/Playground/Development/claudeboard
git add -A
git commit -m "refactor: delete LaunchConfirmationDialog (no longer used)"
git push
```

---

### Task 8: Deploy and manual test

**Step 1: Deploy**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && make deploy`
Expected: Builds, kills old instance, deploys to /Applications, relaunches

**Step 2: Manual verification checklist**

- [ ] Quick Launch: type text, press Enter → session starts (unchanged)
- [ ] Create Task: fill prompt, click Create → card appears AND session starts immediately (no launch dialog)
- [ ] Play button on backlog card → session starts immediately (no launch dialog)
- [ ] Resume button on waiting card → session resumes immediately (no launch dialog)
- [ ] Drag card from Backlog to In Progress → session starts (no dialog)
