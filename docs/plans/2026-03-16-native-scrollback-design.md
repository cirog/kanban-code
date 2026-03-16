# Native Scrollback — Design Document

**Date:** 2026-03-16
**Status:** Approved

## Problem

Scrolling up in the terminal triggers tmux copy-mode, which shows a yellow cursor and steals input focus. The user cannot type to Claude while scrolled up — they must first exit copy-mode by pressing a key or scrolling back to the bottom.

## Solution

Remove the tmux copy-mode scroll interception and let SwiftTerm handle scrolling natively via its built-in scrollback buffer. This preserves input focus at all times — the user can scroll up to read history while continuing to type at the bottom.

## Changes

### Remove from TerminalCache

1. **`scrollWheelMonitor`** — the entire `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` block. Without this, scroll events flow through to SwiftTerm's native `scrollWheel()` → `scrollUp()/scrollDown()`.
2. **`copyModeSessions: Set<String>`** — no longer tracking copy-mode state.
3. **`copyModeExitTime: [String: ContinuousClock.Instant]`** — no longer needed for cooldown.
4. **`sessionUnderPoint()`** — only used by the scroll monitor.
5. **Copy-mode key handler** (lines 316-337 in the `shiftEnterMonitor` block) — the section that exits copy-mode on keypress. Without programmatic copy-mode entry, this is dead code.

### Keep

- **Shift+Enter handler** — still needed for sending `\n` instead of `\r`.
- **URL click handler** — unrelated to scrolling.
- **All terminal rendering** — BatchedTerminalView, TerminalContainerNSView unchanged.

## Trade-offs

- SwiftTerm's scrollback buffer may be shorter than tmux's. SwiftTerm defaults to 10,000 lines which is sufficient for most sessions.
- Users who want tmux copy-mode can still enter it manually via tmux prefix + `[`. The key handler removal means they'd need to exit manually too (press `q` or `Esc` in tmux).
