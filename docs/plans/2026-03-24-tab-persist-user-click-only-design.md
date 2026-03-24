# Tab Persist on User Click Only

**Date:** 2026-03-24
**Status:** Approved

## Problem

`handleTabChange()` calls `onSetLastTab(selectedTab.rawValue)` on every
`selectedTab` mutation — including programmatic changes (card switch, terminal
focus notifications, checkpoint mode). This causes `lastTab` to be saved as
`.prompt` or `.terminal` from code paths the user never initiated. When the user
later clicks a card (e.g., a finished scheduled task in waiting), `defaultTab`
restores the programmatically-saved tab instead of using the `initialTab`
priority chain (terminal → history → prompt).

## Root Cause

Single write path: both user clicks (Picker) and programmatic assignments
(`selectedTab = .terminal`) flow through `onChange(of: selectedTab)` →
`handleTabChange()` → `onSetLastTab()`.

## Solution

Separate the two write paths at the binding level:

1. **Remove** `onSetLastTab` from `handleTabChange()`. It keeps its reaction
   logic (focus terminal, load history) unchanged.

2. **Add** a `userTabBinding` computed property that wraps `selectedTab` with a
   setter that calls `onSetLastTab` before writing.

3. **Change** the segmented `Picker` from `$selectedTab` to `userTabBinding`.

Result:
- User clicks the Picker → `userTabBinding.set` → persists + sets state →
  `onChange` fires → reactions run.
- Programmatic `selectedTab = X` → sets state → `onChange` fires → reactions
  run, no persist.

No new state variables, no flags, no additional conditionals.

## Files Changed

| File | Change |
|------|--------|
| `Sources/ClaudeBoard/CardDetailView.swift` | Add `userTabBinding`, use in Picker, remove persist from `handleTabChange` |
| `Tests/ClaudeBoardTests/` | Test that `defaultTab` uses `initialTab` when no user-saved tab exists |
