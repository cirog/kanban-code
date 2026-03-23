# Smart Tab Selection — Design

**Date:** 2026-03-23
**Status:** Approved

## Problem

Two competing tab-setters cause:
1. **Incomplete tab memory** — `lastTab` is only restored for `.terminal` and `.history`. If the user manually switched to `.prompt`, `.summary`, or `.description`, that choice is lost on card re-selection.
2. **Empty history on card switch** — when a card with `lastTab = "history"` is selected, `ContentView.onChange(of: selectedCardId)` sets the tab to `.history` before `CardDetailView.task(id:)` runs. The task block wipes `turns = []` then calls `defaultTab(for:)` which also lands on `.history` — but `onChange(of: selectedTab)` doesn't fire (no change), so `loadFullHistory()` is never called.

## Solution: Single Tab Authority (Approach A)

CardDetailView becomes the sole owner of tab selection on card change. ContentView stops setting tabs.

### Tab Priority

1. **Last manual tab** — whatever the user explicitly picked, always wins (persisted in `link.lastTab`)
2. **Terminal** — if tmux is attached (`tmuxLink != nil`)
3. **History** — if the card has a session (`slug != nil`)
4. **Prompt** — fallback for cards with no session/tmux

### Changes

#### 1. ContentView — remove tab restore from `onChange(of: selectedCardId)`

Delete the `lastTab` restore logic (lines ~345-354). The handler either becomes empty or keeps only non-tab logic.

#### 2. `defaultTab(for:)` — honor all saved tabs

```swift
private func defaultTab(for card: ClaudeBoardCard) -> DetailTab {
    if let saved = card.link.lastTab, let tab = DetailTab(rawValue: saved) {
        switch tab {
        case .terminal where card.link.tmuxLink != nil: return tab
        case .history, .prompt, .summary: return tab
        case .description where card.link.todoistId != nil: return tab
        default: break  // .terminal without tmux, .description without todoist
        }
    }
    return DetailTab.initialTab(for: card)
}
```

Validates the saved tab is still displayable but otherwise trusts the user's last choice.

#### 3. `DetailTab.initialTab(for:)` — new fallback priority

```swift
static func initialTab(for card: ClaudeBoardCard) -> DetailTab {
    if card.link.tmuxLink != nil { return .terminal }
    if card.link.slug != nil { return .history }
    return .prompt
}
```

Removed `.description` from fallback chain and redundant final `.history`.

#### 4. Fix empty history — ensure load in `.task(id:)`

The `.task(id:)` block already loads history when `selectedTab == .history`, but this path fails when the tab "hasn't changed" from SwiftUI's perspective. Ensure `loadFullHistory()` + `startHistoryWatcher()` always run when landing on `.history`, regardless of whether `onChange(of: selectedTab)` fires.

### Files Touched

| File | Change |
|------|--------|
| `ContentView.swift` | Remove tab restore from `onChange(of: selectedCardId)` |
| `CardDetailView.swift` | Fix `defaultTab(for:)`, update `initialTab(for:)`, ensure history loads |

### Testing

- New unit tests for `defaultTab` priority: saved tab restored, saved terminal without tmux falls through, fallback order
- Manual: switch between cards left on each tab type, verify restoration + history content
