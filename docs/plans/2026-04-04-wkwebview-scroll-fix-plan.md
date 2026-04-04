# WKWebView Trackpad Scroll Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix trackpad scrolling in WKWebView-based tabs (History+, Prompts) by wrapping the web view in an NSView that forwards scroll events directly.

**Architecture:** Add a reusable `WebViewScrollWrapper` NSView subclass that overrides `scrollWheel(with:)` to forward events to its child WKWebView, bypassing SwiftUI's responder chain attenuation. Apply to both `HistoryPlusView` and `PromptsWebView`.

**Tech Stack:** Swift 6.2, macOS 26, SwiftUI NSViewRepresentable, WebKit WKWebView

---

### Task 1: Add WebViewScrollWrapper and fix HistoryPlusView

**Files:**
- Modify: `Sources/ClaudeBoard/HistoryPlusView.swift`

**Step 1: Add `WebViewScrollWrapper` class above `HistoryPlusView`**

Add this class at the top of the file, after the imports:

```swift
/// Wraps a WKWebView to forward trackpad scroll events directly,
/// bypassing SwiftUI's responder chain which attenuates scroll deltas.
final class WebViewScrollWrapper: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        webView.scrollWheel(with: event)
    }
}
```

**Step 2: Change `HistoryPlusView` to use the wrapper**

Change the `NSViewRepresentable` typealias and methods:

Replace `makeNSView`:
```swift
func makeNSView(context: Context) -> WebViewScrollWrapper {
    let config = WKWebViewConfiguration()
    config.preferences.isElementFullscreenEnabled = false
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    loadHTML(into: webView, coordinator: context.coordinator)
    return WebViewScrollWrapper(webView: webView)
}
```

Replace `updateNSView`:
```swift
func updateNSView(_ wrapper: WebViewScrollWrapper, context: Context) {
    let webView = wrapper.webView
    let coord = context.coordinator
    let currentLine = turns.last?.lineNumber ?? -1
    if currentLine == coord.lastLineNumber {
        return
    }

    if coord.didInitialLoad && coord.lastLineNumber != -1 {
        incrementalUpdate(webView: webView, coordinator: coord)
    } else {
        loadHTML(into: webView, coordinator: coord)
    }
}
```

**Step 3: Build to verify compilation**

Run: `cd ~/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: Build succeeds with no errors.

**Step 4: Commit**

```bash
git add Sources/ClaudeBoard/HistoryPlusView.swift
git commit -m "fix: wrap WKWebView in scroll-forwarding NSView for History+ tab

Trackpad scroll events were attenuated by SwiftUI's responder chain,
causing millimetric scrolling. The wrapper forwards scrollWheel events
directly to the WKWebView."
```

---

### Task 2: Apply same fix to PromptsWebView

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift` (~line 2176)

**Step 1: Change `PromptsWebView` to use `WebViewScrollWrapper`**

Replace `makeNSView`:
```swift
func makeNSView(context: Context) -> WebViewScrollWrapper {
    let config = WKWebViewConfiguration()
    config.preferences.isElementFullscreenEnabled = false
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    loadContent(into: webView, coordinator: context.coordinator)
    return WebViewScrollWrapper(webView: webView)
}
```

Replace `updateNSView`:
```swift
func updateNSView(_ wrapper: WebViewScrollWrapper, context: Context) {
    let webView = wrapper.webView
    let coord = context.coordinator
    guard html != coord.lastHTML else { return }
    loadContent(into: webView, coordinator: coord)
}
```

**Step 2: Build to verify compilation**

Run: `cd ~/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: Build succeeds with no errors.

**Step 3: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "fix: apply scroll-forwarding wrapper to PromptsWebView"
```

---

### Task 3: Deploy and verify

**Step 1: Deploy**

Run: `cd ~/Playground/Development/claudeboard && make deploy`

**Step 2: Manual verification**

In ClaudeBoard:
1. Open a card with conversation history → History tab
2. Two-finger trackpad scroll — should scroll normally with momentum
3. Click-drag the scrollbar — should still work
4. Switch to a card with queued prompts → Prompts tab
5. Two-finger trackpad scroll — should scroll normally
6. Trigger a new message (or switch cards) — auto-scroll to bottom should still work

**Step 3: Push**

```bash
cd ~/Playground/Development/claudeboard && git push
```
