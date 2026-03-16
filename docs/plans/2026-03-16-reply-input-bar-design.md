# Reply Tab Input Bar Design

**Date**: 2026-03-16
**Status**: Approved

## Problem

The Reply tab shows clean rendered output but is read-only. To respond to Claude, users must switch to the Terminal tab and type in the raw tmux view, losing the clean reading experience.

## Solution

A fixed text input area at the bottom of the Reply tab. User types a message, presses Enter to send it to the tmux terminal. The Reply tab auto-refreshes when Claude finishes responding via the existing `.claudeBoardHistoryChanged` file watcher notification.

## Layout

```
┌─────────────────────────────────┐
│  Reply tab content (WKWebView)  │
│  - rendered markdown output     │
│  - scrollable                   │
│                                 │
├─────────────────────────────────┤
│  ┌───────────────────────┐ Send │
│  │ Type a message...     │  ➤   │
│  │                       │      │
│  └───────────────────────┘      │
└─────────────────────────────────┘
```

- Input area: TextEditor, 3-line default height, Dracula-styled
- Send button: right side, purple accent
- Enter sends, Shift+Enter for newline
- Input clears after sending

## Send Mechanism

1. User presses Enter (or clicks Send)
2. Text sent to tmux via existing `TmuxAdapter.sendKeys()`
3. Append `\r` to submit
4. Clear input field
5. Show subtle "Sent" border flash (green, fades after 1s)

## Auto-Refresh

1. Reuse `.claudeBoardHistoryChanged` notification (existing file watcher on .jsonl)
2. When Reply tab is active and notification fires, reset `lastRenderedTurnIndex` and call `loadReply()`
3. Debounce: 0.5s (same as History tab)

## Styling

- Input area: `#44475a` background, `#f8f8f2` text, `#6272a4` placeholder
- Border: 1px `#6272a4`, rounded corners
- Send button: `#bd93f9` purple accent capsule
- Sent indicator: green border flash, 1s fade

## Scope Exclusions

- No local chat history in the tab
- No message editing or resend
- No image/file attachment
