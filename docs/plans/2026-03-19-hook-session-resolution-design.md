# Hook Session Resolution Design

## Problem

When a Claude Code session undergoes a context reset (`--resume`), a new session ID is created while keeping the same conversation slug. The CardReconciler correctly chains these sessions during its 5-second background cycle, but hook events that arrive *before* reconciliation runs cannot find the card:

1. `BackgroundOrchestrator.doNotify()` calls `coordinationStore.linkForSession(newSessionId)` — returns `nil`
2. `autoSendQueuedPrompt()` also returns `nil` — queued prompt never fires
3. Notification degrades to generic "Session done" instead of the card's title

**Window:** Up to 5 seconds between context reset and next reconciliation cycle.

**Impact:**
- Missed auto-send of queued prompts (the Stop event already passed, won't re-fire)
- Degraded notifications (generic title)
- No immediate column update (waits for next reconciliation)

## Design

### Approach: Slug-based fallback with eager registration

Add a `resolveLink(sessionId:transcriptPath:)` method to `BackgroundOrchestrator` that:

1. **Fast path:** `coordinationStore.linkForSession(sessionId)` — returns immediately if session is already registered
2. **Fallback:** If nil and `transcriptPath` is available:
   a. Read slug from the `.jsonl` file via `JsonlParser.extractMetadata(from:)` (lightweight — stops after finding slug in first few lines)
   b. Call `coordinationStore.findBySlug(slug)` to find the card
   c. If found, call `coordinationStore.addSessionPath(linkId:sessionId:path:isCurrent:)` to eagerly register the new session
   d. Return the card

This eliminates the 5s gap entirely. The reconciler still runs its normal cycle, but the session is already linked when it gets there (reconciler handles this gracefully — it's an exact sessionId match at that point).

### Callers

Replace `coordinationStore.linkForSession(sessionId)` with `resolveLink(sessionId:transcriptPath:)` in:

- `doNotify(sessionId:)` — needs the hook event's `transcriptPath` passed in
- `autoSendQueuedPrompt(sessionId:)` — same

Both callers are in `BackgroundOrchestrator` and have access to the hook event (or can receive the transcript path as a parameter).

### Method signatures

```swift
// BackgroundOrchestrator (private)
private func resolveLink(sessionId: String, transcriptPath: String?) async -> Link?

// Updated callers
private func doNotify(sessionId: String, transcriptPath: String?) async
private func autoSendQueuedPrompt(sessionId: String, transcriptPath: String?) async
```

### Activity detector

No changes needed. The `ClaudeCodeActivityDetector` already stores hook events by session ID (`lastEvents[newSessionId]`). After reconciliation updates the card's `sessionLink` to the new session ID, `activityState(for: newSessionId)` returns the correct state from the hook event. The only minor degradation is Ctrl+C fast detection (requires `sessionPaths[sessionId]` from `pollActivity`) — this resolves on the next 5s tick.

### Data integrity

- `addSessionPath` marks the new session as `is_current=1` and demotes the old one to `is_current=0`
- The `session_paths` table has `PRIMARY KEY (link_id, session_id)` so duplicate registration is impossible
- If `findBySlug` returns nil (truly new session, no card exists), `resolveLink` returns nil and the normal reconciler creates the card on its next cycle

## Files to modify

| File | Change |
|------|--------|
| `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift` | Add `resolveLink()`, update `doNotify()` and `autoSendQueuedPrompt()` signatures |
| `Tests/ClaudeBoardCoreTests/BackgroundOrchestratorTests.swift` | Test slug fallback resolution (if test file exists, otherwise new) |

## Not in scope

- Changing the hook script (`hook.sh`) — slug is not in Claude Code's hook stdin
- Changing `CoordinationStore` — it stays a pure DB layer
- Changing `ClaudeCodeActivityDetector` — already works correctly
- Changing `CardReconciler` — already handles slug chaining
