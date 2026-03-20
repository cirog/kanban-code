# New Task Dialog — Name Only (No Auto-Prompt)

## Problem

The New Task dialog currently uses the text field as both the card name and the
prompt sent to Claude. This means every new task immediately sends that text as
an instruction to Claude, which isn't always desired — sometimes you just want to
name a session and interact with Claude manually.

## Design

**Approach A (minimal):** The dialog text becomes the card name only.
`promptBody` is set to `nil`. Claude launches in tmux with no initial prompt.

### Changes

1. **`NewTaskDialog.swift`** — Change placeholder text from "What needs to be
   done?" to "Card name" (or similar). The `onCreate` callback still fires with
   the text, but semantically it's a name, not a prompt.

2. **`ContentView.swift` → `createManualTask`** — Set `promptBody: nil` instead
   of `promptBody: trimmed`. The `name` field gets the dialog text. The card
   still launches immediately (`startImmediately: true`).

3. **`ContentView.swift` → `startCard`** — Currently falls back to
   `card.link.promptBody ?? card.link.name ?? ""` when building the prompt. Change
   this to only use `promptBody` — if it's nil, the prompt is empty and
   `executeLaunch` skips `sendPrompt` via its existing `if !prompt.isEmpty` guard.

### What stays the same

- `executeLaunch` — already guards `sendPrompt` with `if !prompt.isEmpty`. No
  change needed.
- `LaunchSession.launch` — receives the prompt but only the tmux `sendPrompt`
  call uses it. The session creation (cd + claude command) is independent.
- `CardReconciler` — promptBody matching (priority 3) won't fire since
  promptBody is nil. Session detection still works via tmux name and session file
  polling.
- `CardDetailView` — "Original Prompt" section already guards with
  `if let original = card.link.promptBody, !original.isEmpty`. Won't render.
- `PromptBuilder` — still works; returns empty string when promptBody is nil and
  name is used only as display label.
- `Link.displayTitle` — falls back from name → promptBody → sessionId. Since
  name is always set, this is fine.

### Column flow

1. Card created with `column: .inProgress`
2. `executeLaunch` launches Claude in tmux (no prompt sent)
3. Claude sits at `>` prompt — activity detector sees idle state
4. Reconciler assigns Waiting column based on activity state

## Testing

- Existing `PromptBuilderTests` — verify empty prompt when promptBody is nil
- New test: `createManualTask` with name-only produces Link with nil promptBody
- New test: `startCard` with nil promptBody produces empty prompt string
