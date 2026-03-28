# Background Suspension — Design

## Problem

ClaudeBoard draws ~28W when backgrounded (87% of system load). AlDente flags it as "Using Significant Energy". The cause: 4 polling loops run unconditionally regardless of app visibility. The `appIsActive` flag is set but never checked.

## Approach

When `appIsActive == false`, suspend all polling loops. Hook watcher and notifications stay active (event-driven, near-zero cost). Badge updates already work via hook events.

## What suspends

| Loop | Location | Interval | Guard mechanism |
|------|----------|----------|-----------------|
| refresh-timer | ContentView:598 | 3s | `store.appIsActive` |
| backgroundTick | BackgroundOrchestrator:59 | 5s | `orchestrator.appIsActive` (new property) |
| usage-poll | ContentView:606 | 5s | `store.appIsActive` |
| pathPolling | CardDetailView:1681 | 1.5s | `NSApp.isActive` (AppKit, available in view layer) |

## What stays active

- hook-watcher (DispatchSource, event-driven)
- settings-watcher (DispatchSource, event-driven)
- Pushover/macOS notifications (triggered by hook events)
- Dock badge (updated in hook-event handler)
- Terminal processes (external tmux)

## Resume path

`didBecomeActive` already calls `store.reconcile()` + `systemTray.update()`. Polling loops resume on their next tick after `appIsActive` flips true.

## Implications

- Card status may be up to 3s stale on foreground — covered by existing `didBecomeActive` reconcile
- Usage bars may show 5min-stale data — acceptable (API granularity is 5min)
- Expected idle power: <1W (from ~28W)
