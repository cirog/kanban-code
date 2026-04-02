# Aggressive Pruning — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate periodic CPU spikes by pruning everything older than 3 days — sessions, cards, hook events, and logs.

**Architecture:** Five independent changes, each testable in isolation. Discovery age filter is highest impact (reduces session count from ~1,047 to ~30). Log rotation prevents unbounded file growth.

**Tech Stack:** Swift 6.2, Swift Testing framework

---

### Task 1: Discovery — skip sessions older than 3 days

**Files:**
- Modify: `Sources/ClaudeBoardCore/Adapters/ClaudeCode/ClaudeCodeSessionDiscovery.swift`
- Test: `Tests/ClaudeBoardCoreTests/SessionDiscoveryTests.swift`

**Step 1: Write the failing test**

Add to `SessionDiscoveryTests.swift`:

```swift
@Test("Skips .jsonl files older than 3 days")
func skipsOldSessions() async throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let projectDir = (dir as NSString).appendingPathComponent("-Users-test-age")
    try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

    // Recent session (should be included)
    let recentPath = (projectDir as NSString).appendingPathComponent("recent.jsonl")
    try #"{"type":"user","sessionId":"recent","message":{"content":"Hi"},"cwd":"/test"}"#
        .write(toFile: recentPath, atomically: true, encoding: .utf8)

    // Old session — backdate mtime to 4 days ago
    let oldPath = (projectDir as NSString).appendingPathComponent("old.jsonl")
    try #"{"type":"user","sessionId":"old","message":{"content":"Hi"},"cwd":"/test"}"#
        .write(toFile: oldPath, atomically: true, encoding: .utf8)
    let fourDaysAgo = Date.now.addingTimeInterval(-4 * 24 * 3600)
    try FileManager.default.setAttributes(
        [.modificationDate: fourDaysAgo],
        ofItemAtPath: oldPath
    )

    let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
    let sessions = try await discovery.discoverSessions()

    #expect(sessions.count == 1)
    #expect(sessions[0].id == "recent")
}
```

**Step 2: Run test to verify it fails**

Run: `cd ~/Playground/Development/claudeboard && swift test --filter "skipsOldSessions" 2>&1 | tail -10`
Expected: FAIL — old session is currently returned (count == 2)

**Step 3: Write minimal implementation**

In `ClaudeCodeSessionDiscovery.swift`, add an age cutoff at the top of `discoverSessions()`:

```swift
public func discoverSessions() async throws -> [Session] {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: claudeDir) else { return [] }

    let cutoff = Date.now.addingTimeInterval(-3 * 24 * 3600) // 3 days

    let projectDirs = try fileManager.contentsOfDirectory(atPath: claudeDir)
    // ...existing code...
```

Then inside the jsonl scanning loop, after the mtime check, add the age filter:

```swift
guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
      let mtime = attrs[.modificationDate] as? Date else {
    continue
}

// Skip files older than 3 days
guard mtime > cutoff else { continue }
```

Also evict cached sessions that are now too old (add after the existing eviction loop for removed files):

```swift
// Evict sessions from this dir that no longer exist or are too old
if let oldIds = dirSessionIds[dirName] {
    for removedId in oldIds.subtracting(dirSessions) {
        cachedSessions.removeValue(forKey: removedId)
    }
}
```

No other changes needed — the existing `fileMtimes` check is before the age filter, so cached recent sessions skip the age check (correct behavior, they were already validated).

**Step 4: Run test to verify it passes**

Run: `cd ~/Playground/Development/claudeboard && swift test --filter "skipsOldSessions" 2>&1 | tail -10`
Expected: PASS

**Step 5: Run all discovery tests**

Run: `cd ~/Playground/Development/claudeboard && swift test --filter "ClaudeCodeSessionDiscovery" 2>&1 | tail -10`
Expected: All pass (existing tests use fresh files, all within 3 days)

**Step 6: Commit**

```bash
git add Sources/ClaudeBoardCore/Adapters/ClaudeCode/ClaudeCodeSessionDiscovery.swift Tests/ClaudeBoardCoreTests/SessionDiscoveryTests.swift
git commit -m "perf: skip session discovery for files older than 3 days

Reduces discovered sessions from ~1,047 to ~30 on a typical install,
eliminating the main source of card bloat and SwiftUI diffing overhead."
```

---

### Task 2: AutoCleanup — prune all Done cards older than 72h

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/AutoCleanup.swift`
- Test: `Tests/ClaudeBoardCoreTests/AutoCleanupTests.swift`

**Step 1: Update the existing test to expect new behavior**

The test `removesOldDoneCards_discoveredOnly` currently expects old manual and todoist cards to survive. Update it:

Replace the existing `removesOldDoneCards_discoveredOnly` test with:

```swift
@Test func removesAllOldDoneCards() {
    let oldDiscovered = Link(
        column: .done,
        updatedAt: Date.now.addingTimeInterval(-73 * 3600), // >72h
        source: .discovered
    )
    let oldManual = Link(
        column: .done,
        updatedAt: Date.now.addingTimeInterval(-73 * 3600),
        source: .manual
    )
    let oldTodoist = Link(
        column: .done,
        updatedAt: Date.now.addingTimeInterval(-73 * 3600),
        source: .todoist
    )
    let recentDiscovered = Link(
        column: .done,
        updatedAt: Date.now.addingTimeInterval(-12 * 3600),
        source: .discovered
    )

    let result = AutoCleanup.clean(links: [oldDiscovered, oldManual, oldTodoist, recentDiscovered])

    #expect(result.count == 1) // only recentDiscovered survives
    #expect(result[0].id == recentDiscovered.id)
}
```

**Step 2: Run test to verify it fails**

Run: `cd ~/Playground/Development/claudeboard && swift test --filter "removesAllOldDoneCards" 2>&1 | tail -10`
Expected: FAIL — old manual and todoist cards still included (count == 3)

**Step 3: Write minimal implementation**

In `AutoCleanup.swift`, change the age filter. Remove the `source == .discovered` check and change `maxAgeHours` default from 24 to 72:

```swift
public static func clean(
    links: [Link],
    maxAgeHours: Int = 72,
    maxCards: Int = 1000
) -> [Link] {
    let cutoff = Date.now.addingTimeInterval(-Double(maxAgeHours) * 3600)

    // ... scheduled task cleanup unchanged ...

    // Remove old Done cards (any source)
    cleaned = cleaned.filter { link in
        if link.column == .done && link.updatedAt < cutoff {
            return false
        }
        return true
    }

    // ... cap logic unchanged ...
```

**Step 4: Run test to verify it passes**

Run: `cd ~/Playground/Development/claudeboard && swift test --filter "AutoCleanup" 2>&1 | tail -15`
Expected: All pass. Note: `capsAtMaxCards` and `keepsNonDoneCards_evenIfVeryOld` should still pass without changes.

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/AutoCleanup.swift Tests/ClaudeBoardCoreTests/AutoCleanupTests.swift
git commit -m "perf: prune all Done cards older than 72h regardless of source

Previously only pruned source=.discovered cards older than 24h.
Now prunes all Done cards older than 72h (3 days)."
```

---

### Task 3: Run AutoCleanup after every reconcile

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`

**Step 1: Add cleanup before dispatch**

In `BoardStore.reconcile()`, just before the `dispatch(.reconciled(result))` call (around line 1391), add:

```swift
// Prune old Done cards before dispatching
let prunedLinks = AutoCleanup.clean(links: mergedLinks)
```

Then use `prunedLinks` instead of `mergedLinks` in the `ReconciliationResult` constructor:

```swift
let result = ReconciliationResult(
    links: prunedLinks,  // was: mergedLinks
    sessions: sessions,
    // ... rest unchanged
)
```

**Step 2: Build and run all tests**

Run: `cd ~/Playground/Development/claudeboard && swift test 2>&1 | tail -15`
Expected: All pass.

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "perf: run AutoCleanup after every reconcile

Previously cleanup only ran on DB load (cold start). Now runs every
cycle, keeping card count bounded at ~30 active cards."
```

---

### Task 4: Hook event pruning — discard events older than 3 days

**Files:**
- Modify: `Sources/ClaudeBoardCore/Adapters/ClaudeCode/HookEventStore.swift`

**Step 1: Add pruning to readAllStoredEvents**

After appending new events to `cachedEvents`, prune old ones:

```swift
let newEvents = Self.parseEvents(from: text)
cachedEvents.append(contentsOf: newEvents)

// Prune events older than 3 days
let cutoff = Date.now.addingTimeInterval(-3 * 24 * 3600)
cachedEvents.removeAll { $0.timestamp < cutoff }

return cachedEvents
```

**Step 2: Build and run all tests**

Run: `cd ~/Playground/Development/claudeboard && swift test 2>&1 | tail -15`
Expected: All pass (no existing tests for hook event age).

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/Adapters/ClaudeCode/HookEventStore.swift
git commit -m "perf: prune hook events older than 3 days

Reduces in-memory event count from ~8,700 to ~200, speeding up
PID iteration and reconciler snapshot construction."
```

---

### Task 5: Log rotation + persistent FileHandle + cached formatter

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/KanbanCodeLog.swift`

**Step 1: Rewrite KanbanCodeLog**

Replace the entire file:

```swift
import Foundation

/// Centralized logging for ClaudeBoard — writes to ~/.kanban-code/logs/kanban-code.log.
/// Thread-safe, fire-and-forget. Use from anywhere in ClaudeBoardCore or ClaudeBoard.
public enum ClaudeBoardLog {

    private static let logDir: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let logPath: String = {
        (logDir as NSString).appendingPathComponent("kanban-code.log")
    }()

    private static let rotatedPath: String = {
        (logDir as NSString).appendingPathComponent("kanban-code.log.1")
    }()

    private static let queue = DispatchQueue(label: "kanban-code.log", qos: .utility)

    /// Reusable formatter — ISO8601DateFormatter init is expensive (ICU setup).
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    /// Persistent file handle — opened once, reused for all writes.
    private nonisolated(unsafe) static var handle: FileHandle?

    /// Maximum log size before rotation (10 MB).
    private static let maxSize: UInt64 = 10 * 1024 * 1024

    public nonisolated static func info(_ subsystem: String, _ message: String) {
        write("INFO", subsystem, message)
    }

    public nonisolated static func warn(_ subsystem: String, _ message: String) {
        write("WARN", subsystem, message)
    }

    public nonisolated static func error(_ subsystem: String, _ message: String) {
        write("ERROR", subsystem, message)
    }

    private nonisolated static func write(_ level: String, _ subsystem: String, _ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(subsystem)] \(message)\n"

        queue.async {
            // Open handle if needed
            if handle == nil {
                rotateIfNeeded()
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                handle = FileHandle(forWritingAtPath: logPath)
                handle?.seekToEndOfFile()
            }

            guard let h = handle, let data = line.data(using: .utf8) else { return }
            h.write(data)

            // Check size periodically (every write is fine — it's a cheap stat on the open fd)
            if h.offsetInFile > maxSize {
                h.closeFile()
                handle = nil
                rotateIfNeeded()
            }
        }
    }

    /// Rotate: delete .1, move current → .1.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logPath),
              let attrs = try? fm.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64,
              size > maxSize else { return }

        try? fm.removeItem(atPath: rotatedPath)
        try? fm.moveItem(atPath: logPath, toPath: rotatedPath)
    }
}
```

**Step 2: Build**

Run: `cd ~/Playground/Development/claudeboard && swift build 2>&1 | tail -5`
Expected: Build succeeded.

**Step 3: Run all tests**

Run: `cd ~/Playground/Development/claudeboard && swift test 2>&1 | tail -15`
Expected: All pass.

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/Infrastructure/KanbanCodeLog.swift
git commit -m "perf: log rotation + persistent FileHandle + cached formatter

- Keep FileHandle open instead of open/seek/close per write
- Reuse single ISO8601DateFormatter (eliminates ICU init per entry)
- Rotate at 10MB: current → .1, delete old .1
- Eliminates I/O storms during 1,000+ entry bursts"
```

---

### Task 6: Deploy, truncate old log, verify

**Files:** None (runtime verification)

**Step 1: Deploy**

Run: `cd ~/Playground/Development/claudeboard && make deploy`

**Step 2: Truncate the existing 383MB log**

Run: `> ~/.kanban-code/logs/kanban-code.log`

**Step 3: Verify card count**

After ClaudeBoard finishes its first reconcile (visible in the board), check the log:

Run: `grep "reconciled" ~/.kanban-code/logs/kanban-code.log | tail -3`
Expected: Card count should be ~20-50 instead of ~1,150.

**Step 4: Verify no freeze on app switch**

Switch to another app, wait 10s, switch back. No freeze.

**Step 5: Push**

```bash
git push
```
