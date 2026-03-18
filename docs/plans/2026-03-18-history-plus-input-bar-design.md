# History+ Input Bar Design

## Goal

Add a multi-line input bar below the History+ tab's chat view, allowing users to type messages and send them to the active Claude session.

## Component

A new `HistoryPlusInputBar` SwiftUI view placed below `HistoryPlusView` in a VStack.

### Visual Design
- Multi-line `TextEditor` with Dracula styling (`#44475A` background, `#F8F8F2` text)
- Minimum height ~80pt (4+ visible lines), max ~150pt, auto-grows with content
- Font size ~14pt with placeholder text "Type a message..."
- Send button on the right: `arrow.up.circle.fill` icon, purple (`#BD93F9`) when text present, gray (`#6272A4`) when empty
- Green flash on border after send

### Behavior
- **Enter** = newline (not send)
- **Cmd+Enter** = sends the message
- **Send button click** = sends the message
- Sends via the existing `onSendReplyText` callback (writes to tmux stdin)
- Clears input after sending
- Disabled when input is empty/whitespace-only

### Wiring
- In `CardDetailView`, the `.historyPlus` case wraps `HistoryPlusView` + `HistoryPlusInputBar` in a VStack
- `HistoryPlusInputBar.onSend` calls `onSendReplyText`

## Files
- **New**: `Sources/ClaudeBoard/HistoryPlusInputBar.swift`
- **Modify**: `Sources/ClaudeBoard/CardDetailView.swift` — wrap historyPlus case in VStack with input bar
