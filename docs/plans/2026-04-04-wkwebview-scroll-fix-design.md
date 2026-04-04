# WKWebView Trackpad Scroll Fix

## Problem

Trackpad two-finger scrolling in the History+ tab produces only millimetric
movements. Clicking the scrollbar works fine. The issue is immediate and
consistent — not triggered by content length or specific actions.

**Root cause:** `WKWebView` embedded via `NSViewRepresentable` in SwiftUI. macOS
trackpad `scrollWheel` events travel through SwiftUI's responder chain, which
attenuates scroll deltas before they reach the WKWebView's internal
`NSScrollView`. Scrollbar clicks bypass this chain entirely (direct `NSScroller`
hit-testing), which is why they work.

## Approach

Wrap the `WKWebView` in a thin `NSView` subclass (`WebViewScrollWrapper`) that
overrides `scrollWheel(with:)` to forward events directly to the WKWebView.

Alternatives considered:
- **CSS overflow container** — loses native scrollbar appearance, affects
  `window.scrollTo()` auto-scroll logic.
- **Internal NSScrollView configuration** — relies on WKWebView's private view
  hierarchy, fragile across macOS updates.

## Changes

### `Sources/ClaudeBoard/HistoryPlusView.swift`

1. Add `WebViewScrollWrapper: NSView` (~15 lines):
   - Holds a `WKWebView` reference
   - Overrides `scrollWheel(with:)` → forwards to `webView.scrollWheel(with:)`
   - Adds WKWebView as subview with autoresizing mask
2. Change `NSViewRepresentable` to return `WebViewScrollWrapper`:
   - `makeNSView` creates wrapper, returns it
   - `updateNSView` extracts `.webView` from wrapper for JS calls

### `Sources/ClaudeBoard/CardDetailView.swift`

Same wrapper pattern applied to `PromptsTabWebView` (another WKWebView
`NSViewRepresentable` at ~line 2180).

### No changes to

- HTML/CSS (`chatCSS`, `htmlPage`)
- Coordinator logic
- `CardDetailView` layout (VStack/ZStack structure)
- Auto-scroll-to-bottom (`window.scrollTo` in incremental update JS)

## Testing

Manual verification:
- Trackpad two-finger scroll works with normal momentum in History tab
- Scrollbar click-drag still works
- Auto-scroll to bottom on new messages still works
- Prompts tab scrolling also works
