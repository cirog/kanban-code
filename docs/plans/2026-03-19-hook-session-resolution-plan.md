# Hook Session Resolution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the 5-second window where hook events for context-reset sessions can't find their card, by adding a slug-based fallback with eager session registration.

**Architecture:** When `linkForSession(sessionId)` returns nil in `BackgroundOrchestrator`, fall back to reading the slug from the `.jsonl` transcript via `JsonlParser.extractMetadata()`, then `findBySlug()` to locate the card, and `addSessionPath()` to eagerly register the new session. All changes are in `BackgroundOrchestrator` — no changes to `CoordinationStore`, `CardReconciler`, or `ClaudeCodeActivityDetector`.

**Tech Stack:** Swift 6.2, macOS 26, Swift Testing framework, SQLite (via CoordinationStore)

---

### Task 1: Write failing test for `resolveLink` slug fallback

**Files:**
- Create: `Tests/ClaudeBoardCoreTests/SessionResolutionTests.swift`

**Context:** `BackgroundOrchestrator` is a `@unchecked Sendable` class with many dependencies (discovery, coordinationStore, activityDetector, hookEventStore, tmux, notifier, registry, todoistSync). Testing `resolveLink` directly requires constructing the full orchestrator. Since `resolveLink` will be private, we test via `processHookEvents()` behavior — but that requires mocking `NotifierPort`, `ActivityDetector`, etc.

A simpler approach: extract the resolution logic as a **static** pure function that takes `coordinationStore` and returns `Link?`. This avoids needing a full orchestrator in tests. But that changes the design slightly.

**Best approach:** Test the resolution logic end-to-end through `CoordinationStore` + `JsonlParser` — the two collaborators `resolveLink` depends on. We already have tests for both individually; the new test verifies the *combined* flow: "given a card with slug X in the DB and a .jsonl file with slug X, looking up by session ID fails but looking up by slug succeeds and registers the session."

**Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("Session Resolution")
struct SessionResolutionTests {

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Write a minimal .jsonl file with a slug in the init message.
    func writeJsonl(at path: String, slug: String) throws {
        let line = """
        {"type":"system","slug":"\(slug)","cwd":"/test"}
        """
        try line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("resolveLink finds card by slug when sessionId is unknown")
    func resolveLinkSlugFallback() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        // Card exists with old session, slug "my-slug"
        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(
                sessionId: "old-session-id",
                sessionPath: "/old/path.jsonl",
                slug: "my-slug"
            )
        )
        try await store.writeLinks([card])

        // New session .jsonl file with same slug
        let jsonlPath = (dir as NSString).appendingPathComponent("new-session.jsonl")
        try writeJsonl(at: jsonlPath, slug: "my-slug")

        // linkForSession with new ID returns nil
        let directLookup = try await store.linkForSession("new-session-id")
        #expect(directLookup == nil)

        // resolveLink should find the card via slug fallback
        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "new-session-id",
            transcriptPath: jsonlPath,
            coordinationStore: store
        )
        #expect(resolved != nil)
        #expect(resolved?.id == card.id)

        // Session should now be registered — future lookups hit fast path
        let fastPath = try await store.linkForSession("new-session-id")
        #expect(fastPath != nil)
        #expect(fastPath?.id == card.id)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SessionResolutionTests`
Expected: FAIL — `resolveLink` does not exist on `BackgroundOrchestrator`

**Step 3: Write minimal implementation**

Add to `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift`, inside the `BackgroundOrchestrator` class, after the `// MARK: - Private` section (around line 200):

```swift
    // MARK: - Session resolution

    /// Resolve a session ID to a Link. Fast path: exact DB match.
    /// Fallback: read slug from .jsonl transcript, find card by slug, eagerly register session.
    static func resolveLink(
        sessionId: String,
        transcriptPath: String?,
        coordinationStore: CoordinationStore
    ) async throws -> Link? {
        // Fast path: session already registered
        if let link = try coordinationStore.linkForSession(sessionId) {
            return link
        }

        // Fallback: read slug from transcript, find card by slug
        guard let path = transcriptPath,
              let metadata = try await JsonlParser.extractMetadata(from: path),
              let slug = metadata.slug,
              let link = try coordinationStore.findBySlug(slug) else {
            return nil
        }

        // Eagerly register so future lookups hit the fast path
        ClaudeBoardLog.info("reconciler", "Hook resolution: session \(sessionId.prefix(8)) → card \(link.id.prefix(12)) via slug \(slug)")
        try coordinationStore.addSessionPath(linkId: link.id, sessionId: sessionId, path: path)
        // Re-read to get updated session link
        return try coordinationStore.linkById(link.id)
    }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SessionResolutionTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/SessionResolutionTests.swift Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift
git commit -m "feat: add resolveLink with slug-based fallback for context-reset sessions"
```

---

### Task 2: Write failing test for nil transcript path (no fallback possible)

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/SessionResolutionTests.swift`

**Step 1: Write the failing test**

Add to `SessionResolutionTests`:

```swift
    @Test("resolveLink returns nil when sessionId unknown and no transcript path")
    func resolveLinkNoTranscript() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "old-id", slug: "slug-1")
        )
        try await store.writeLinks([card])

        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "unknown-id",
            transcriptPath: nil,
            coordinationStore: store
        )
        #expect(resolved == nil)
    }
```

**Step 2: Run test to verify it passes** (this should already pass with the implementation from Task 1)

Run: `swift test --filter SessionResolutionTests`
Expected: PASS (both tests)

**Step 3: Commit** (if test needed any fixes)

No commit needed if both pass — move to Task 3.

---

### Task 3: Write failing test for transcript without slug (no fallback possible)

**Files:**
- Modify: `Tests/ClaudeBoardCoreTests/SessionResolutionTests.swift`

**Step 1: Write the failing test**

```swift
    @Test("resolveLink returns nil when transcript has no slug")
    func resolveLinkNoSlugInTranscript() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let card = Link(
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "old-id", slug: "slug-1")
        )
        try await store.writeLinks([card])

        // Write a .jsonl with no slug field
        let jsonlPath = (dir as NSString).appendingPathComponent("no-slug.jsonl")
        try """
        {"type":"system","cwd":"/test"}
        """.write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let resolved = try await BackgroundOrchestrator.resolveLink(
            sessionId: "unknown-id",
            transcriptPath: jsonlPath,
            coordinationStore: store
        )
        #expect(resolved == nil)
    }
```

**Step 2: Run test to verify it passes**

Run: `swift test --filter SessionResolutionTests`
Expected: PASS (all three)

**Step 3: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/SessionResolutionTests.swift
git commit -m "test: add edge case tests for resolveLink fallback"
```

---

### Task 4: Wire `resolveLink` into `doNotify`

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift:155,167,184,204-210`

**Step 1: Update `doNotify` signature and callers**

Change `doNotify` at line 204 to accept `transcriptPath`:

```swift
    private func doNotify(sessionId: String, transcriptPath: String? = nil) async {
```

Replace line 210:
```swift
        let link = try? await coordinationStore.linkForSession(sessionId)
```
with:
```swift
        let link = try? await Self.resolveLink(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            coordinationStore: coordinationStore
        )
```

**Step 2: Update call sites in `processHookEvents`**

The `Stop` handler (line 140) captures `sessionId` but not `transcriptPath`. Add capture of `transcriptPath` from the event:

At line 139, after `let sessionId = event.sessionId`, add:
```swift
                    let transcriptPath = event.transcriptPath
```

At line 155, change:
```swift
                        await self.doNotify(sessionId: sessionId)
```
to:
```swift
                        await self.doNotify(sessionId: sessionId, transcriptPath: transcriptPath)
```

The `Notification` handler (line 184), change:
```swift
                        await self?.doNotify(sessionId: sessionId)
```
to:
```swift
                        await self?.doNotify(sessionId: sessionId, transcriptPath: event.transcriptPath)
```

Wait — `event` is not captured in the Notification Task closure. Need to capture it. At line 173, after `let eventTime = event.timestamp`, add:
```swift
                    let transcriptPath = event.transcriptPath
```
Then at line 184:
```swift
                        await self?.doNotify(sessionId: sessionId, transcriptPath: transcriptPath)
```

**Step 3: Run all tests**

Run: `swift test`
Expected: ALL PASS

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift
git commit -m "fix: wire resolveLink into doNotify for slug-based card resolution"
```

---

### Task 5: Wire `resolveLink` into `autoSendQueuedPrompt`

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift:262-264,167`

**Step 1: Update `autoSendQueuedPrompt` signature**

Change line 262:
```swift
    private func autoSendQueuedPrompt(sessionId: String) async {
```
to:
```swift
    private func autoSendQueuedPrompt(sessionId: String, transcriptPath: String? = nil) async {
```

Replace line 264:
```swift
            guard let link = try await coordinationStore.linkForSession(sessionId) else {
```
with:
```swift
            guard let link = try await Self.resolveLink(
                sessionId: sessionId,
                transcriptPath: transcriptPath,
                coordinationStore: coordinationStore
            ) else {
```

**Step 2: Update call site**

At line 167 (in the Stop handler), change:
```swift
                        await self.autoSendQueuedPrompt(sessionId: sessionId)
```
to:
```swift
                        await self.autoSendQueuedPrompt(sessionId: sessionId, transcriptPath: transcriptPath)
```

(`transcriptPath` was already captured in Task 4.)

**Step 3: Run all tests**

Run: `swift test`
Expected: ALL PASS

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BackgroundOrchestrator.swift
git commit -m "fix: wire resolveLink into autoSendQueuedPrompt for slug-based resolution"
```

---

### Task 6: Build, deploy, and verify

**Step 1: Run full test suite**

Run: `swift test`
Expected: ALL PASS, 0 failures

**Step 2: Deploy**

Run: `make deploy`
Expected: Build succeeds, ClaudeBoard relaunches

**Step 3: Commit design and plan docs**

```bash
git add docs/plans/2026-03-19-hook-session-resolution-design.md docs/plans/2026-03-19-hook-session-resolution-plan.md
git commit -m "docs: hook session resolution design and plan"
git push
```
