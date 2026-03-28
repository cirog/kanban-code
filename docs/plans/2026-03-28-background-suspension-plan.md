# Background Suspension Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Suspend all polling when ClaudeBoard is backgrounded to eliminate ~28W idle power draw.

**Architecture:** Add `appIsActive` guards to 4 polling loops. BackgroundOrchestrator gets its own `appIsActive` property (set from ContentView alongside BoardStore's). CardDetailView uses `NSApp.isActive` directly.

**Tech Stack:** Swift 6, SwiftUI, AppKit

---

### Task 1: Add `appIsActive` to BackgroundOrchestrator

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift`

**Step 1: Write the failing test**

File: `Tests/ClaudeBoardCoreTests/BackgroundOrchestratorTests.swift` (create)

```swift
import Testing
@testable import ClaudeBoardCore

struct BackgroundOrchestratorTests {
    @Test func appIsActiveDefaultsToTrue() {
        let orch = BackgroundOrchestrator(
            discovery: StubDiscovery(),
            coordinationStore: StubCoordinationStore(),
            activityDetector: StubActivityDetector()
        )
        #expect(orch.appIsActive == true)
    }
}

// Minimal stubs — just enough to compile
private struct StubDiscovery: SessionDiscovery {
    func discoverSessions() async throws -> [DiscoveredSession] { [] }
}

private final class StubCoordinationStore: CoordinationStore {
    // Use a throwaway in-memory store
}

private final class StubActivityDetector: ActivityDetector {
    func handleHookEvent(_ event: HookEvent) async {}
    func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] { [:] }
    func activityState(for sessionId: String) async -> ActivityState? { nil }
    func resolvePendingStops() async -> [String] { [] }
}
```

> **Note:** The stubs above may need adjustment to match the exact protocol signatures. Check the protocol definitions if compilation fails and add any required methods.

**Step 2: Run test to verify it fails**

Run: `cd ~/Playground/Development/claudeboard && swift test --filter BackgroundOrchestratorTests`
Expected: FAIL — `appIsActive` does not exist on BackgroundOrchestrator

**Step 3: Add the property**

In `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift`, add after `public var isRunning = false` (line 12):

```swift
public var appIsActive = true
```

**Step 4: Run test to verify it passes**

Run: `cd ~/Playground/Development/claudeboard && swift test --filter BackgroundOrchestratorTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift Tests/ClaudeBoardCoreTests/BackgroundOrchestratorTests.swift
git commit -m "feat: add appIsActive property to BackgroundOrchestrator"
```

---

### Task 2: Guard `backgroundTick` on `appIsActive`

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift:59-63`

**Step 1: Write the failing test**

Add to `Tests/ClaudeBoardCoreTests/BackgroundOrchestratorTests.swift`:

```swift
@Test func backgroundTickSkipsWhenInactive() async {
    let detector = CountingActivityDetector()
    let orch = BackgroundOrchestrator(
        discovery: StubDiscovery(),
        coordinationStore: StubCoordinationStore(),
        activityDetector: detector
    )
    orch.appIsActive = false

    // backgroundTick is private, but it's called by start().
    // Instead, test that after a brief run with appIsActive=false,
    // the detector was never polled.
    // We'll use a different approach: make backgroundTick internal for testing.
    // Actually — the simplest test: start the orchestrator, wait >5s, check poll count.
    // That's too slow. Instead, expose backgroundTick as package-internal.
}
```

> **Pragmatic approach:** Since `backgroundTick` is private and the orchestrator's loop has a 5s sleep, a unit test would be slow. Instead, add the guard and verify via integration: the energy drop is the test. Skip the dedicated unit test for this guard — the property test from Task 1 + visual verification is sufficient.

**Step 2: Add the guard**

In `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift`, change the `start()` loop (lines 59-63) from:

```swift
backgroundTask = Task { [weak self] in
    while !Task.isCancelled {
        await self?.backgroundTick()
        try? await Task.sleep(for: .seconds(5))
    }
}
```

to:

```swift
backgroundTask = Task { [weak self] in
    while !Task.isCancelled {
        if self?.appIsActive ?? false {
            await self?.backgroundTick()
        }
        try? await Task.sleep(for: .seconds(5))
    }
}
```

**Step 3: Run all tests to verify no regressions**

Run: `cd ~/Playground/Development/claudeboard && swift test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift
git commit -m "perf: skip backgroundTick when app is inactive"
```

---

### Task 3: Guard `refresh-timer` and `usage-poll` in ContentView

**Files:**
- Modify: `Sources/ClaudeBoard/ContentView.swift:598-612`

**Step 1: Add guard to refresh-timer**

Change lines 598-605 from:

```swift
.task(id: "refresh-timer") {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { break }
        await store.reconcile()
        systemTray.update()
    }
}
```

to:

```swift
.task(id: "refresh-timer") {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { break }
        guard store.appIsActive else { continue }
        await store.reconcile()
        systemTray.update()
    }
}
```

**Step 2: Add guard to usage-poll**

Change lines 606-612 from:

```swift
.task(id: "usage-poll") {
    await usageService.start()
    while !Task.isCancelled {
        usageData = await usageService.currentUsage()
        try? await Task.sleep(for: .seconds(5))
    }
}
```

to:

```swift
.task(id: "usage-poll") {
    await usageService.start()
    while !Task.isCancelled {
        if store.appIsActive {
            usageData = await usageService.currentUsage()
        }
        try? await Task.sleep(for: .seconds(5))
    }
}
```

**Step 3: Wire `appIsActive` to orchestrator**

In the `didResignActiveNotification` handler (line 678-680), add the orchestrator update:

Change from:

```swift
.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
    store.appIsActive = false
}
```

to:

```swift
.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
    store.appIsActive = false
    orchestrator.appIsActive = false
}
```

And in `didBecomeActiveNotification` (line 671-677), change from:

```swift
.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
    store.appIsActive = true
    Task {
        await store.reconcile()
        systemTray.update()
    }
}
```

to:

```swift
.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
    store.appIsActive = true
    orchestrator.appIsActive = true
    Task {
        await store.reconcile()
        systemTray.update()
    }
}
```

**Step 4: Build to verify compilation**

Run: `cd ~/Playground/Development/claudeboard && swift build`
Expected: Build succeeds

**Step 5: Run all tests**

Run: `cd ~/Playground/Development/claudeboard && swift test`
Expected: All tests pass

**Step 6: Commit**

```bash
git add Sources/ClaudeBoard/ContentView.swift
git commit -m "perf: suspend refresh-timer and usage-poll when app is inactive"
```

---

### Task 4: Guard `pathPolling` in CardDetailView

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift:1683`

**Step 1: Add guard inside polling loop**

In `startPathPolling()`, change the loop body (line 1683) from:

```swift
while !Task.isCancelled {
    // Query panes for extra shell sessions ...
    if let result = try? await ShellCommand.run(
```

to:

```swift
while !Task.isCancelled {
    guard NSApp.isActive else {
        try? await Task.sleep(for: .milliseconds(1500))
        continue
    }
    // Query panes for extra shell sessions ...
    if let result = try? await ShellCommand.run(
```

> **Why `NSApp.isActive` instead of passing a flag?** CardDetailView is a value-type View with no access to the store. `NSApp.isActive` is a simple, thread-safe read with zero coupling. It mirrors exactly what the ContentView notification handlers track.

**Step 2: Build to verify compilation**

Run: `cd ~/Playground/Development/claudeboard && swift build`
Expected: Build succeeds

**Step 3: Run all tests**

Run: `cd ~/Playground/Development/claudeboard && swift test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "perf: suspend path polling when app is inactive"
```

---

### Task 5: Manual verification

**Step 1: Deploy and test**

Run: `cd ~/Playground/Development/claudeboard && make deploy`

**Step 2: Verify background suspension**

1. Open ClaudeBoard, let it settle for 10s
2. Switch to another app (Cmd+Tab)
3. Open Activity Monitor → Energy tab
4. Observe ClaudeBoard's energy impact — should drop to near-zero within 5s
5. Switch back to ClaudeBoard — board should refresh immediately

**Step 3: Verify notifications still work**

1. Background ClaudeBoard
2. Trigger a Claude session Stop event (let a session finish)
3. Verify Pushover notification arrives
4. Verify dock badge updates

**Step 4: Final commit with all docs**

```bash
git add docs/plans/
git commit -m "docs: background suspension design and plan"
git push
```
