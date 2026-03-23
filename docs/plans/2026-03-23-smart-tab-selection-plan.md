# Smart Tab Selection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make CardDetailView the sole tab authority on card switch, restore all saved tab types, and fix the empty-history bug.

**Architecture:** Remove the competing tab-setting logic from ContentView. Expand `defaultTab(for:)` to honor all persisted tab values. Ensure history always loads when landing on the history tab, even when the tab binding doesn't change from SwiftUI's perspective.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`, `@Test`, `#expect`)

---

### Task 1: Write failing tests for tab selection priority

**Files:**
- Create: `Tests/ClaudeBoardTests/TabSelectionTests.swift`

**Step 1: Write the failing tests**

Create `Tests/ClaudeBoardTests/TabSelectionTests.swift`:

```swift
import Testing
@testable import ClaudeBoard
import ClaudeBoardCore

@Suite("Tab Selection Priority")
struct TabSelectionTests {

    // MARK: - initialTab (fallback when no lastTab saved)

    @Test("Fallback: tmux card → terminal")
    func fallbackTmux() {
        let card = ClaudeBoardCard(
            link: Link(id: "1", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       tmuxLink: TmuxLink(sessionName: "s1"))
        )
        #expect(DetailTab.initialTab(for: card) == .terminal)
    }

    @Test("Fallback: session card (slug, no tmux) → history")
    func fallbackHistory() {
        let card = ClaudeBoardCard(
            link: Link(id: "2", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc")
        )
        #expect(DetailTab.initialTab(for: card) == .history)
    }

    @Test("Fallback: bare card (no tmux, no slug) → prompt")
    func fallbackPrompt() {
        let card = ClaudeBoardCard(
            link: Link(id: "3", name: "t", projectPath: "/p", column: .backlog, source: .manual)
        )
        #expect(DetailTab.initialTab(for: card) == .prompt)
    }

    // MARK: - defaultTab (saved lastTab restoration)

    @Test("Saved history tab is restored")
    func savedHistory() {
        let card = ClaudeBoardCard(
            link: Link(id: "4", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "history")
        )
        #expect(DetailTab.defaultTab(for: card) == .history)
    }

    @Test("Saved prompt tab is restored")
    func savedPrompt() {
        let card = ClaudeBoardCard(
            link: Link(id: "5", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "prompt")
        )
        #expect(DetailTab.defaultTab(for: card) == .prompt)
    }

    @Test("Saved summary tab is restored")
    func savedSummary() {
        let card = ClaudeBoardCard(
            link: Link(id: "6", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "summary")
        )
        #expect(DetailTab.defaultTab(for: card) == .summary)
    }

    @Test("Saved description tab is restored when todoist present")
    func savedDescriptionWithTodoist() {
        let card = ClaudeBoardCard(
            link: Link(id: "7", name: "t", projectPath: "/p", column: .inProgress, source: .todoist,
                       todoistId: "123", lastTab: "description")
        )
        #expect(DetailTab.defaultTab(for: card) == .description)
    }

    @Test("Saved description tab falls through when todoist removed")
    func savedDescriptionWithoutTodoist() {
        let card = ClaudeBoardCard(
            link: Link(id: "8", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "description")
        )
        // No todoistId → falls through to initialTab → .history (has slug)
        #expect(DetailTab.defaultTab(for: card) == .history)
    }

    @Test("Saved terminal tab is restored when tmux present")
    func savedTerminalWithTmux() {
        let card = ClaudeBoardCard(
            link: Link(id: "9", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", tmuxLink: TmuxLink(sessionName: "s1"), lastTab: "terminal")
        )
        #expect(DetailTab.defaultTab(for: card) == .terminal)
    }

    @Test("Saved terminal tab falls through when tmux gone")
    func savedTerminalWithoutTmux() {
        let card = ClaudeBoardCard(
            link: Link(id: "10", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", lastTab: "terminal")
        )
        // No tmuxLink → falls through to initialTab → .history (has slug)
        #expect(DetailTab.defaultTab(for: card) == .history)
    }

    @Test("No saved tab → uses initialTab fallback")
    func noSavedTab() {
        let card = ClaudeBoardCard(
            link: Link(id: "11", name: "t", projectPath: "/p", column: .inProgress, source: .discovered,
                       slug: "abc", tmuxLink: TmuxLink(sessionName: "s1"))
        )
        // No lastTab → initialTab → .terminal (has tmux)
        #expect(DetailTab.defaultTab(for: card) == .terminal)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter TabSelectionTests 2>&1 | tail -30`

Expected: compilation errors — `defaultTab` is a private instance method on `CardDetailView`, not accessible from tests. The `initialTab` tests may also fail because the current implementation returns `.description` or `.history` where we expect `.prompt`.

---

### Task 2: Make `defaultTab` testable — extract to `DetailTab` static method

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift:12-22` (DetailTab enum)
- Modify: `Sources/ClaudeBoard/CardDetailView.swift:872-882` (defaultTab instance method)

**Step 1: Move `defaultTab` logic into `DetailTab` as a static method**

Replace the `DetailTab` enum (lines 12-22) with:

```swift
enum DetailTab: String {
    case terminal, history, prompt, description, summary

    static func initialTab(for card: ClaudeBoardCard) -> DetailTab {
        if card.link.tmuxLink != nil { return .terminal }
        if card.link.slug != nil { return .history }
        return .prompt
    }

    static func defaultTab(for card: ClaudeBoardCard) -> DetailTab {
        if let saved = card.link.lastTab, let tab = DetailTab(rawValue: saved) {
            switch tab {
            case .terminal where card.link.tmuxLink != nil: return tab
            case .history, .prompt, .summary: return tab
            case .description where card.link.todoistId != nil: return tab
            default: break
            }
        }
        return initialTab(for: card)
    }
}
```

**Step 2: Update the old private `defaultTab` call site**

Replace the private `defaultTab(for:)` method (lines 872-882) with a one-line delegate:

```swift
    private func defaultTab(for card: ClaudeBoardCard) -> DetailTab {
        DetailTab.defaultTab(for: card)
    }
```

**Step 3: Run tests to verify they pass**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test --filter TabSelectionTests 2>&1 | tail -30`

Expected: all 11 tests PASS.

**Step 4: Run full test suite**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -30`

Expected: all tests PASS (existing behavior preserved via delegate).

**Step 5: Commit**

```bash
git add Tests/ClaudeBoardTests/TabSelectionTests.swift Sources/ClaudeBoard/CardDetailView.swift
git commit -m "feat: smart tab selection — restore all saved tabs with priority chain"
```

---

### Task 3: Remove competing tab-setter from ContentView

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift:342-356`

**Step 1: Remove the tab restore logic from `onChange(of: selectedCardId)`**

Replace lines 342-356:

```swift
            .onChange(of: store.state.selectedCardId) {
                if let cardId = store.state.selectedCardId,
                   let card = store.state.cards.first(where: { $0.id == cardId }) {
                    // Restore persisted tab if valid for this card
                    if let saved = card.link.lastTab, let tab = DetailTab(rawValue: saved) {
                        switch tab {
                        case .terminal where card.link.tmuxLink != nil: detailTab = tab
                        case .history: detailTab = tab
                        default: detailTab = DetailTab.initialTab(for: card)
                        }
                    } else {
                        detailTab = DetailTab.initialTab(for: card)
                    }
                }
            }
```

With just:

```swift
            .onChange(of: store.state.selectedCardId) {
                // Tab selection is handled by CardDetailView.task(id:)
            }
```

**Step 2: Run full test suite**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -30`

Expected: all tests PASS.

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "fix: remove competing tab-setter from ContentView"
```

---

### Task 4: Fix empty history on card switch

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift:240-266` (`.task(id:)` block)

**Step 1: Ensure history always loads when landing on history tab**

The current `.task(id: card.id)` block sets `selectedTab = defaultTab(for: card)` and then checks `if selectedTab == .history`. The problem is that when both the old and new card land on `.history`, SwiftUI sees no binding change, so `onChange(of: selectedTab)` never fires — but the `turns` array was already wiped on line 242.

The fix is already in the `.task(id:)` block — it explicitly loads history. The issue was the *race* with ContentView setting the tab first. With ContentView's tab-setter removed (Task 3), the `.task(id:)` block is now the sole path, so the explicit history load on line 256-258 will always run correctly.

**However**, there's a subtle edge case: if the previous card was also on `.history` and `selectedTab` is already `.history` before `.task(id:)` runs, SwiftUI may not re-trigger the `.task(id:)` block's `selectedTab = defaultTab(for: card)` assignment as a change — but the `.task(id:)` block itself always runs because it's keyed on `card.id`. The explicit `if selectedTab == .history` check on line 256 handles this correctly.

Verify this works by manual testing after deploying. If the history still appears empty, the fix is to call `loadFullHistory()` unconditionally (not gated on `selectedTab == .history`) since it's idempotent and cheap.

Replace lines 253-261:

```swift
            // Reset tab to a valid one for this card (skip auto-focus)
            suppressTerminalFocus = true
            selectedTab = defaultTab(for: card)
            // Always load history — needed by multiple tabs and prevents empty-history
            // bug when the tab binding doesn't change from SwiftUI's perspective
            await loadFullHistory()
            if selectedTab == .history {
                startHistoryWatcher()
            }
```

This removes the separate `loadHistory()` path and always loads full history regardless of tab. `startHistoryWatcher()` still only runs for the history tab.

**Step 2: Run full test suite**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && swift test 2>&1 | tail -30`

Expected: all tests PASS.

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "fix: always load history on card switch to prevent empty-history bug"
```

---

### Task 5: Deploy and manually verify

**Step 1: Deploy**

Run: `cd ~/Obsidian/MyVault/Playground/Development/claudeboard && make deploy`

**Step 2: Manual test matrix**

| Scenario | Expected |
|----------|----------|
| Click card left on History tab | History tab shown with content (not empty) |
| Click card left on Prompt tab | Prompt tab restored |
| Click card left on Summary tab | Summary tab restored |
| Click card left on Terminal (tmux alive) | Terminal tab restored |
| Click card left on Terminal (tmux gone) | Falls through → History (if slug) or Prompt |
| Click card left on Description (todoist) | Description tab restored |
| Click new card (no lastTab) with tmux | Terminal tab |
| Click new card (no lastTab) with slug | History tab |
| Click new card (no lastTab) bare | Prompt tab |
| Switch away from History, switch back | History shows content (not empty) |

**Step 3: Final commit and push**

```bash
git push
```
