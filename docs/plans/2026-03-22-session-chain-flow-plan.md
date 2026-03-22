# Session Chain Flow Reconstruction — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reconstruct full conversation history across chained sessions in the History and Prompts tabs, using the existing `session_links` table.

**Architecture:** New `SessionChain` domain entity built lazily from `session_links` DB rows + JSONL timestamp parsing. Wired through the Elm architecture via new Action/Effect pairs. Views consume the chain from `AppState.chainByCardId` — no DB access from views. Prompts tab gets WKWebView markdown rendering.

**Tech Stack:** Swift 6.2, SwiftUI, WKWebView, SQLite (raw via CoordinationStore), Swift Testing framework.

**Design doc:** `docs/plans/2026-03-22-session-chain-flow-design.md`

---

## Task 1: SessionChain Domain Entity

**Files:**
- Create: `Sources/ClaudeBoardCore/Domain/Entities/SessionChain.swift`
- Test: `Tests/ClaudeBoardCoreTests/SessionChainTests.swift`

**Step 1: Write the failing test**

Create `Tests/ClaudeBoardCoreTests/SessionChainTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("SessionChain")
struct SessionChainTests {

    @Test("TransitionReason.label returns correct display text")
    func transitionReasonLabels() {
        #expect(TransitionReason.initial.label == "Started")
        #expect(TransitionReason.resumed(gap: 3600).label == "Resumed")
        #expect(TransitionReason.interrupted(gap: 300).label == "Interrupted")
        #expect(TransitionReason.newSession(gap: 86400).label == "New session")
    }

    @Test("TransitionReason.gapDescription formats durations correctly")
    func gapDescriptions() {
        #expect(TransitionReason.initial.gapDescription == nil)
        #expect(TransitionReason.resumed(gap: 3600).gapDescription == "1h gap")
        #expect(TransitionReason.resumed(gap: 7500).gapDescription == "2h 5m gap")
        #expect(TransitionReason.interrupted(gap: 90).gapDescription == "1m gap")
        #expect(TransitionReason.newSession(gap: 86400).gapDescription == "1d gap")
        #expect(TransitionReason.newSession(gap: 90000).gapDescription == "1d 1h gap")
        #expect(TransitionReason.resumed(gap: 45).gapDescription == "<1m gap")
    }

    @Test("ChainSegment is identifiable by sessionId")
    func segmentIdentity() {
        let seg = ChainSegment(
            id: "sess-abc", path: "/test.jsonl", matchedBy: "tmux",
            firstTimestamp: .now, lastTimestamp: .now, slug: nil,
            transitionReason: .initial
        )
        #expect(seg.id == "sess-abc")
    }

    @Test("SessionChain hasMore indicates pagination")
    func chainHasMore() {
        let chain = SessionChain(cardId: "card-1", segments: [], totalSegments: 10)
        #expect(chain.hasMore == true)

        let fullChain = SessionChain(cardId: "card-1", segments: [], totalSegments: 0)
        #expect(fullChain.hasMore == false)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SessionChainTests 2>&1 | head -20`
Expected: FAIL — `SessionChain`, `ChainSegment`, `TransitionReason` not defined.

**Step 3: Write minimal implementation**

Create `Sources/ClaudeBoardCore/Domain/Entities/SessionChain.swift`:

```swift
import Foundation

/// Reason for a session transition in a chain. Best-effort detection.
public enum TransitionReason: Sendable, Equatable {
    case initial                        // first session in chain
    case resumed(gap: TimeInterval)     // same slug as previous
    case interrupted(gap: TimeInterval) // previous ended with Ctrl+C
    case newSession(gap: TimeInterval)  // fallback

    /// Human-readable label for display.
    public var label: String {
        switch self {
        case .initial: "Started"
        case .resumed: "Resumed"
        case .interrupted: "Interrupted"
        case .newSession: "New session"
        }
    }

    /// Formatted gap duration, e.g. "2h 15m gap". Nil for .initial.
    public var gapDescription: String? {
        let gap: TimeInterval
        switch self {
        case .initial: return nil
        case .resumed(let g): gap = g
        case .interrupted(let g): gap = g
        case .newSession(let g): gap = g
        }

        let totalMinutes = Int(gap) / 60
        if totalMinutes < 1 { return "<1m gap" }

        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 && days == 0 { parts.append("\(minutes)m") }

        return parts.joined(separator: " ") + " gap"
    }
}

/// One session in a card's chain, with timing and transition metadata.
public struct ChainSegment: Sendable, Identifiable {
    public let id: String              // sessionId
    public let path: String            // JSONL file path
    public let matchedBy: String       // "tmux" or "discovered"
    public let firstTimestamp: Date     // ordering key
    public let lastTimestamp: Date?     // for gap to next session
    public let slug: String?           // for resume detection
    public let transitionReason: TransitionReason

    public init(
        id: String, path: String, matchedBy: String,
        firstTimestamp: Date, lastTimestamp: Date?, slug: String?,
        transitionReason: TransitionReason
    ) {
        self.id = id
        self.path = path
        self.matchedBy = matchedBy
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.slug = slug
        self.transitionReason = transitionReason
    }
}

/// Ordered chain of sessions belonging to a single card.
public struct SessionChain: Sendable {
    public let cardId: String
    public let segments: [ChainSegment] // sorted oldest → newest
    public let totalSegments: Int       // may be > segments.count if paginated

    public init(cardId: String, segments: [ChainSegment], totalSegments: Int) {
        self.cardId = cardId
        self.segments = segments
        self.totalSegments = totalSegments
    }

    /// Whether more segments exist beyond what's loaded.
    public var hasMore: Bool { totalSegments > segments.count }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SessionChainTests 2>&1 | tail -5`
Expected: All 4 tests PASS.

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/Domain/Entities/SessionChain.swift Tests/ClaudeBoardCoreTests/SessionChainTests.swift
git commit -m "feat: add SessionChain domain entity with transition reason detection"
git push
```

---

## Task 2: SessionChainBuilder — Pure Chain Construction

**Files:**
- Create: `Sources/ClaudeBoardCore/UseCases/SessionChainBuilder.swift`
- Test: `Tests/ClaudeBoardCoreTests/SessionChainBuilderTests.swift`

**Step 1: Write the failing test**

Create `Tests/ClaudeBoardCoreTests/SessionChainBuilderTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("SessionChainBuilder")
struct SessionChainBuilderTests {

    // MARK: - Helpers

    private func makeRawSegment(
        sessionId: String, path: String, matchedBy: String = "tmux",
        slug: String? = nil, firstTimestamp: Date, lastTimestamp: Date? = nil,
        lastLineText: String? = nil
    ) -> SessionChainBuilder.RawSegment {
        SessionChainBuilder.RawSegment(
            sessionId: sessionId, path: path, matchedBy: matchedBy,
            slug: slug, firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp ?? firstTimestamp.addingTimeInterval(600),
            lastLineText: lastLineText
        )
    }

    // MARK: - Sorting

    @Test("Segments are sorted oldest to newest by firstTimestamp")
    func sortsByTimestamp() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let t3 = Date(timeIntervalSince1970: 3000)

        let raw = [
            makeRawSegment(sessionId: "s3", path: "/s3.jsonl", firstTimestamp: t3),
            makeRawSegment(sessionId: "s1", path: "/s1.jsonl", firstTimestamp: t1),
            makeRawSegment(sessionId: "s2", path: "/s2.jsonl", firstTimestamp: t2),
        ]

        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 3)
        #expect(chain.segments.map(\.id) == ["s1", "s2", "s3"])
    }

    // MARK: - Transition Detection

    @Test("First segment gets .initial transition reason")
    func firstIsInitial() {
        let raw = [makeRawSegment(sessionId: "s1", path: "/s1.jsonl", firstTimestamp: .now)]
        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 1)
        #expect(chain.segments[0].transitionReason == .initial)
    }

    @Test("Same slug as previous → .resumed with correct gap")
    func resumedBySameSlug() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t1End = Date(timeIntervalSince1970: 2000) // 1000s session
        let t2 = Date(timeIntervalSince1970: 5600)     // 3600s gap from t1End

        let raw = [
            makeRawSegment(sessionId: "s1", path: "/s1.jsonl", slug: "my-slug", firstTimestamp: t1, lastTimestamp: t1End),
            makeRawSegment(sessionId: "s2", path: "/s2.jsonl", slug: "my-slug", firstTimestamp: t2),
        ]

        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 2)
        #expect(chain.segments[0].transitionReason == .initial)
        if case .resumed(let gap) = chain.segments[1].transitionReason {
            #expect(gap == 3600)
        } else {
            Issue.record("Expected .resumed, got \(chain.segments[1].transitionReason)")
        }
    }

    @Test("Previous ends with interrupted text → .interrupted")
    func interruptedDetection() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t1End = Date(timeIntervalSince1970: 2000)
        let t2 = Date(timeIntervalSince1970: 2300) // 300s gap

        let raw = [
            makeRawSegment(sessionId: "s1", path: "/s1.jsonl", firstTimestamp: t1, lastTimestamp: t1End,
                          lastLineText: "[Request interrupted by user]"),
            makeRawSegment(sessionId: "s2", path: "/s2.jsonl", firstTimestamp: t2),
        ]

        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 2)
        if case .interrupted(let gap) = chain.segments[1].transitionReason {
            #expect(gap == 300)
        } else {
            Issue.record("Expected .interrupted, got \(chain.segments[1].transitionReason)")
        }
    }

    @Test("Slug match takes priority over interrupted detection")
    func slugPriorityOverInterrupted() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t1End = Date(timeIntervalSince1970: 2000)
        let t2 = Date(timeIntervalSince1970: 3000)

        let raw = [
            makeRawSegment(sessionId: "s1", path: "/s1.jsonl", slug: "same-slug",
                          firstTimestamp: t1, lastTimestamp: t1End,
                          lastLineText: "[Request interrupted by user]"),
            makeRawSegment(sessionId: "s2", path: "/s2.jsonl", slug: "same-slug", firstTimestamp: t2),
        ]

        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 2)
        if case .resumed = chain.segments[1].transitionReason {
            // correct — slug match wins
        } else {
            Issue.record("Expected .resumed (slug match priority), got \(chain.segments[1].transitionReason)")
        }
    }

    @Test("No slug match, no interruption → .newSession")
    func newSessionFallback() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t1End = Date(timeIntervalSince1970: 2000)
        let t2 = Date(timeIntervalSince1970: 5000)

        let raw = [
            makeRawSegment(sessionId: "s1", path: "/s1.jsonl", slug: nil, firstTimestamp: t1, lastTimestamp: t1End),
            makeRawSegment(sessionId: "s2", path: "/s2.jsonl", slug: nil, firstTimestamp: t2),
        ]

        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 2)
        if case .newSession(let gap) = chain.segments[1].transitionReason {
            #expect(gap == 3000)
        } else {
            Issue.record("Expected .newSession, got \(chain.segments[1].transitionReason)")
        }
    }

    // MARK: - Pagination

    @Test("totalCount reflects pagination")
    func paginationTotal() {
        let raw = [makeRawSegment(sessionId: "s1", path: "/s1.jsonl", firstTimestamp: .now)]
        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 8)
        #expect(chain.totalSegments == 8)
        #expect(chain.hasMore == true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SessionChainBuilderTests 2>&1 | head -20`
Expected: FAIL — `SessionChainBuilder` not defined.

**Step 3: Write minimal implementation**

Create `Sources/ClaudeBoardCore/UseCases/SessionChainBuilder.swift`:

```swift
import Foundation

/// Pure function: transforms raw DB rows + JSONL metadata into an ordered SessionChain.
public enum SessionChainBuilder {

    /// Raw segment data before transition detection (from DB + JSONL parsing).
    public struct RawSegment: Sendable {
        public let sessionId: String
        public let path: String
        public let matchedBy: String
        public let slug: String?
        public let firstTimestamp: Date
        public let lastTimestamp: Date
        public let lastLineText: String?

        public init(
            sessionId: String, path: String, matchedBy: String, slug: String?,
            firstTimestamp: Date, lastTimestamp: Date, lastLineText: String?
        ) {
            self.sessionId = sessionId
            self.path = path
            self.matchedBy = matchedBy
            self.slug = slug
            self.firstTimestamp = firstTimestamp
            self.lastTimestamp = lastTimestamp
            self.lastLineText = lastLineText
        }
    }

    /// Build a SessionChain from raw segments. Sorts by firstTimestamp, detects transitions.
    public static func build(cardId: String, rawSegments: [RawSegment], totalCount: Int) -> SessionChain {
        let sorted = rawSegments.sorted { $0.firstTimestamp < $1.firstTimestamp }

        var segments: [ChainSegment] = []
        for (i, raw) in sorted.enumerated() {
            let reason: TransitionReason
            if i == 0 {
                reason = .initial
            } else {
                let prev = sorted[i - 1]
                let gap = raw.firstTimestamp.timeIntervalSince(prev.lastTimestamp)
                reason = detectTransition(current: raw, previous: prev, gap: gap)
            }

            segments.append(ChainSegment(
                id: raw.sessionId, path: raw.path, matchedBy: raw.matchedBy,
                firstTimestamp: raw.firstTimestamp, lastTimestamp: raw.lastTimestamp,
                slug: raw.slug, transitionReason: reason
            ))
        }

        return SessionChain(cardId: cardId, segments: segments, totalSegments: totalCount)
    }

    /// Best-effort transition reason detection.
    /// Priority: slug match (.resumed) > interrupted text (.interrupted) > fallback (.newSession).
    private static func detectTransition(current: RawSegment, previous: RawSegment, gap: TimeInterval) -> TransitionReason {
        // 1. Same non-nil slug → resumed
        if let currentSlug = current.slug, let prevSlug = previous.slug,
           currentSlug == prevSlug, !currentSlug.isEmpty {
            return .resumed(gap: gap)
        }

        // 2. Previous session was interrupted
        if let lastLine = previous.lastLineText,
           lastLine.contains("[Request interrupted by user]") {
            return .interrupted(gap: gap)
        }

        // 3. Fallback
        return .newSession(gap: gap)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SessionChainBuilderTests 2>&1 | tail -5`
Expected: All 7 tests PASS.

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/SessionChainBuilder.swift Tests/ClaudeBoardCoreTests/SessionChainBuilderTests.swift
git commit -m "feat: add SessionChainBuilder with transition reason detection"
git push
```

---

## Task 3: CoordinationStore — Chain Segment Query

**Files:**
- Modify: `Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift`
- Modify: `Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift`

**Step 1: Write the failing test**

Add to `Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift` (find existing `@Suite` and add inside):

```swift
    @Test("chainSegments returns sessions for a card ordered by created_at")
    func chainSegmentsForCard() throws {
        let store = try CoordinationStore(path: makeTempDbPath())
        let link = Link(id: "card-1", column: .waiting, source: .manual)
        try store.writeLinks([link], associations: [
            CardReconciler.SessionAssociation(sessionId: "s1", cardId: "card-1", matchedBy: "tmux", path: "/s1.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s2", cardId: "card-1", matchedBy: "tmux", path: "/s2.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s3", cardId: "card-1", matchedBy: "discovered", path: "/s3.jsonl"),
        ])

        let segments = try store.chainSegments(forCardId: "card-1")
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.cardId == "card-1" })
    }

    @Test("chainSegments respects limit")
    func chainSegmentsLimit() throws {
        let store = try CoordinationStore(path: makeTempDbPath())
        let link = Link(id: "card-1", column: .waiting, source: .manual)
        try store.writeLinks([link], associations: [
            CardReconciler.SessionAssociation(sessionId: "s1", cardId: "card-1", matchedBy: "tmux", path: "/s1.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s2", cardId: "card-1", matchedBy: "tmux", path: "/s2.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s3", cardId: "card-1", matchedBy: "tmux", path: "/s3.jsonl"),
        ])

        let segments = try store.chainSegments(forCardId: "card-1", limit: 2)
        #expect(segments.count == 2)
    }

    @Test("chainSegmentCount returns total for a card")
    func chainSegmentCount() throws {
        let store = try CoordinationStore(path: makeTempDbPath())
        let link = Link(id: "card-1", column: .waiting, source: .manual)
        try store.writeLinks([link], associations: [
            CardReconciler.SessionAssociation(sessionId: "s1", cardId: "card-1", matchedBy: "tmux", path: "/s1.jsonl"),
            CardReconciler.SessionAssociation(sessionId: "s2", cardId: "card-1", matchedBy: "tmux", path: "/s2.jsonl"),
        ])

        #expect(try store.chainSegmentCount(forCardId: "card-1") == 2)
        #expect(try store.chainSegmentCount(forCardId: "card-other") == 0)
    }
```

**Note:** Check how `CoordinationStoreTests` creates temp DB instances — match the existing helper pattern (e.g., `makeTempDbPath()`). The test may use a slightly different helper. Read `CoordinationStoreTests.swift` first and match its convention.

**Step 2: Run test to verify it fails**

Run: `swift test --filter CoordinationStoreTests 2>&1 | head -20`
Expected: FAIL — `chainSegments(forCardId:)` and `chainSegmentCount(forCardId:)` not found.

**Step 3: Write minimal implementation**

Add to `CoordinationStore.swift`, after the `allSessionAssociations()` method (around line 357):

```swift
    /// Row data for chain segment construction.
    public struct ChainSegmentRow: Sendable {
        public let sessionId: String
        public let cardId: String
        public let matchedBy: String
        public let path: String?
    }

    /// Get session_links rows for a specific card, ordered by created_at DESC (most recent first).
    /// Use `limit` to cap the number returned (for pagination — load most recent N).
    public func chainSegments(forCardId cardId: String, limit: Int = Int.max) -> [ChainSegmentRow] {
        ensureInitialized()
        var result: [ChainSegmentRow] = []
        var stmt: OpaquePointer?
        let sql = "SELECT session_id, link_id, matched_by, path FROM session_links WHERE link_id = ? ORDER BY created_at DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (cardId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(min(limit, Int(Int32.max))))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let linkId = String(cString: sqlite3_column_text(stmt, 1))
            let matchedBy = String(cString: sqlite3_column_text(stmt, 2))
            let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            result.append(ChainSegmentRow(sessionId: sessionId, cardId: linkId, matchedBy: matchedBy, path: path))
        }
        return result
    }

    /// Count total session_links rows for a card (for pagination: totalSegments).
    public func chainSegmentCount(forCardId cardId: String) -> Int {
        ensureInitialized()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM session_links WHERE link_id = ?", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (cardId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter CoordinationStoreTests 2>&1 | tail -5`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/Infrastructure/CoordinationStore.swift Tests/ClaudeBoardCoreTests/CoordinationStoreTests.swift
git commit -m "feat: add chainSegments query to CoordinationStore"
git push
```

---

## Task 4: TranscriptReader — First/Last Timestamp + Last Line Helpers

**Files:**
- Modify: `Sources/ClaudeBoardCore/Adapters/ClaudeCode/TranscriptReader.swift`
- Modify: `Tests/ClaudeBoardCoreTests/TranscriptReaderTests.swift`

**Step 1: Write the failing test**

Add to `TranscriptReaderTests.swift`:

```swift
    @Test("readBoundaryMetadata extracts first/last timestamps and last line text")
    func readBoundaryMetadata() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test","timestamp":"2026-01-01T10:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi!"}]},"timestamp":"2026-01-01T10:01:00Z"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Fix bug"},"cwd":"/test","timestamp":"2026-01-01T11:30:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Done!"}]},"timestamp":"2026-01-01T11:45:00Z"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let meta = try await TranscriptReader.readBoundaryMetadata(from: path)
        #expect(meta != nil)
        #expect(meta!.firstTimestamp == "2026-01-01T10:00:00Z")
        #expect(meta!.lastTimestamp == "2026-01-01T11:45:00Z")
        #expect(meta!.lastLineText == "Done!")
    }

    @Test("readBoundaryMetadata returns nil for empty file")
    func boundaryMetadataEmpty() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("empty.jsonl")
        try "".write(toFile: path, atomically: true, encoding: .utf8)

        let meta = try await TranscriptReader.readBoundaryMetadata(from: path)
        #expect(meta == nil)
    }

    @Test("readBoundaryMetadata detects interrupted session")
    func boundaryMetadataInterrupted() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test","timestamp":"2026-01-01T10:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-01-01T10:05:00Z"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let meta = try await TranscriptReader.readBoundaryMetadata(from: path)
        #expect(meta!.lastLineText == "[Request interrupted by user]")
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptReaderTests 2>&1 | head -20`
Expected: FAIL — `readBoundaryMetadata` not defined.

**Step 3: Write minimal implementation**

Add to `TranscriptReader.swift`, after the `readRange` method:

```swift
    // MARK: - Boundary metadata for chain construction

    /// Metadata from the first and last conversation turns in a file.
    public struct BoundaryMetadata: Sendable {
        public let firstTimestamp: String
        public let lastTimestamp: String
        public let lastLineText: String    // textPreview of the last turn
        public let slug: String?           // slug from first turn (if present)
    }

    /// Read only the first and last turn's timestamps and the last turn's text.
    /// Lightweight — scans the file but only fully parses the boundaries.
    public static func readBoundaryMetadata(from filePath: String) async throws -> BoundaryMetadata? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        let url = URL(fileURLWithPath: filePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var firstTimestamp: String?
        var lastTimestamp: String?
        var lastLineText: String?
        var slug: String?

        for try await line in handle.bytes.lines {
            guard !line.isEmpty, line.contains("\"type\"") else { continue }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant" else { continue }

            if type == "user" && JsonlParser.isCaveatMessage(obj) { continue }

            let timestamp = obj["timestamp"] as? String

            if firstTimestamp == nil {
                firstTimestamp = timestamp
                // Extract slug from first turn if present
                slug = obj["slug"] as? String
            }

            if let ts = timestamp { lastTimestamp = ts }

            // Track last turn's text preview
            let blocks: [ContentBlock]
            let role: String
            if type == "user" && (JsonlParser.isLocalCommandStdout(obj) || JsonlParser.isTaskNotification(obj)) {
                role = "assistant"
            } else {
                role = type
            }
            if type == "user" {
                blocks = extractUserBlocks(from: obj)
            } else {
                blocks = extractAssistantBlocks(from: obj)
            }
            lastLineText = buildTextPreview(blocks: blocks, role: role)
        }

        guard let first = firstTimestamp, let last = lastTimestamp, let text = lastLineText else { return nil }
        return BoundaryMetadata(firstTimestamp: first, lastTimestamp: last, lastLineText: text, slug: slug)
    }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter TranscriptReaderTests 2>&1 | tail -5`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/Adapters/ClaudeCode/TranscriptReader.swift Tests/ClaudeBoardCoreTests/TranscriptReaderTests.swift
git commit -m "feat: add readBoundaryMetadata to TranscriptReader for chain construction"
git push
```

---

## Task 5: BoardStore — Chain Actions, Effects, and State

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`
- Modify: `Tests/ClaudeBoardCoreTests/ReducerTests.swift`

**Step 1: Write the failing test**

Add to `ReducerTests.swift`:

```swift
    // MARK: - Chain Actions

    @Test("chainLoaded stores chain in state")
    func chainLoaded() {
        var state = AppState()
        let chain = SessionChain(cardId: "card-1", segments: [], totalSegments: 0)

        let effects = Reducer.reduce(state: &state, action: .chainLoaded("card-1", chain))

        #expect(state.chainByCardId["card-1"] != nil)
        #expect(state.chainByCardId["card-1"]?.cardId == "card-1")
        #expect(effects.isEmpty)
    }

    @Test("chainInvalidated removes chain from state")
    func chainInvalidated() {
        var state = AppState()
        state.chainByCardId["card-1"] = SessionChain(cardId: "card-1", segments: [], totalSegments: 0)

        let effects = Reducer.reduce(state: &state, action: .chainInvalidated("card-1"))

        #expect(state.chainByCardId["card-1"] == nil)
        #expect(effects.isEmpty)
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter ReducerTests 2>&1 | head -20`
Expected: FAIL — `chainLoaded`, `chainInvalidated`, `chainByCardId` not found.

**Step 3: Write minimal implementation**

Add to `AppState` (around line 44, after `sessionIdByCardId`):

```swift
    /// Lazily-built session chains per card. Populated when History/Prompts tab opens.
    public var chainByCardId: [String: SessionChain] = [:]
```

Add to the `Action` enum (find it by searching for `enum Action`):

```swift
    case loadChain(cardId: String, limit: Int = 5)
    case chainLoaded(String, SessionChain) // (cardId, chain)
    case chainInvalidated(String) // cardId
```

Add to the `Effect` enum:

```swift
    case loadChain(cardId: String, limit: Int)
```

Add to `Reducer.reduce`, inside the switch:

```swift
        case .loadChain(let cardId, let limit):
            return [.loadChain(cardId: cardId, limit: limit)]

        case .chainLoaded(let cardId, let chain):
            state.chainByCardId[cardId] = chain
            return []

        case .chainInvalidated(let cardId):
            state.chainByCardId[cardId] = nil
            return []
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter ReducerTests 2>&1 | tail -5`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift Tests/ClaudeBoardCoreTests/ReducerTests.swift
git commit -m "feat: add chain actions and state to BoardStore"
git push
```

---

## Task 6: EffectHandler — Chain Loading Effect

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/EffectHandler.swift`

**Step 1: Read EffectHandler.swift to understand the existing pattern**

Run: Read the file to find where effects are handled (the `switch effect` block).

**Step 2: Add chain loading effect handler**

Add a new case inside the effect handler `switch`:

```swift
        case .loadChain(let cardId, let limit):
            Task { @MainActor in
                let rows = coordinationStore.chainSegments(forCardId: cardId, limit: limit)
                let totalCount = coordinationStore.chainSegmentCount(forCardId: cardId)

                // Parse boundary metadata from each JSONL file
                var rawSegments: [SessionChainBuilder.RawSegment] = []
                for row in rows {
                    guard let path = row.path else { continue }

                    let meta = try? await TranscriptReader.readBoundaryMetadata(from: path)
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                    let firstDate: Date
                    let lastDate: Date
                    if let meta, let fd = iso.date(from: meta.firstTimestamp) ?? {
                        iso.formatOptions = [.withInternetDateTime]
                        return iso.date(from: meta.firstTimestamp)
                    }() {
                        firstDate = fd
                        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        lastDate = iso.date(from: meta.lastTimestamp) ?? {
                            iso.formatOptions = [.withInternetDateTime]
                            return iso.date(from: meta.lastTimestamp)
                        }() ?? fd
                    } else {
                        // File missing or empty — use file modification date as fallback
                        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                        firstDate = attrs?[.modificationDate] as? Date ?? .distantPast
                        lastDate = firstDate
                    }

                    // Get slug from Session entity if available
                    let slug = meta?.slug

                    rawSegments.append(SessionChainBuilder.RawSegment(
                        sessionId: row.sessionId, path: path, matchedBy: row.matchedBy,
                        slug: slug, firstTimestamp: firstDate, lastTimestamp: lastDate,
                        lastLineText: meta?.lastLineText
                    ))
                }

                let chain = SessionChainBuilder.build(
                    cardId: cardId, rawSegments: rawSegments, totalCount: totalCount
                )
                store.dispatch(.chainLoaded(cardId, chain))
            }
```

**Important:** Match the existing EffectHandler pattern for the `store` reference and `@MainActor`/`Task` usage. Read the file first and follow the exact convention.

**Step 3: Run full test suite to verify no regressions**

Run: `swift test 2>&1 | tail -10`
Expected: All existing tests still pass.

**Step 4: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/EffectHandler.swift
git commit -m "feat: add chain loading effect handler"
git push
```

---

## Task 7: Chain Invalidation on Reconciliation

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/BoardStore.swift`

**Step 1: Add chain invalidation when sessionIdByCardId changes**

In the `.reconciled` reducer case (around line 824-904 in `BoardStore.swift`), after the reconciler updates `sessionIdByCardId`, invalidate chains for any card whose session changed:

Find the spot where `sessionIdByCardId` gets updated (this happens in the `.reconciled` case or after it). Add:

```swift
            // Invalidate chains for cards whose session changed
            for (cardId, newSessionId) in result.sessionIdByCardId {
                let oldSessionId = state.sessionIdByCardId[cardId]
                if oldSessionId != newSessionId {
                    state.chainByCardId[cardId] = nil
                }
            }
```

**Note:** Read the `.reconciled` case carefully first. The `sessionIdByCardId` update may happen after the reducer via the `persistLinks` effect. Follow wherever `sessionIdByCardId` is rebuilt — that's where invalidation belongs.

**Step 2: Run test suite**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass.

**Step 3: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/BoardStore.swift
git commit -m "feat: invalidate chain cache when session associations change"
git push
```

---

## Task 8: History Tab — Chain-Aware Loading

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`

**Step 1: Read the current history loading code**

Read `CardDetailView.swift` around lines 1410-1510 to understand the existing `allSessionPaths`, `hasChainedSessions`, `loadFullHistory()`, `loadHistory()`, and `loadMoreHistory()`.

**Step 2: Update `allSessionPaths` and `hasChainedSessions` to use chain**

Replace the stubs (lines 1413-1425):

```swift
    /// All session paths from the chain, ordered oldest → newest.
    private var allSessionPaths: [String] {
        if let chain = store.state.chainByCardId[card.id], !chain.segments.isEmpty {
            return chain.segments.map(\.path)
        }
        // Fallback: current session only
        if let current = card.session?.jsonlPath {
            return [current]
        }
        return []
    }

    /// Whether this card has chained sessions.
    private var hasChainedSessions: Bool {
        guard let chain = store.state.chainByCardId[card.id] else { return false }
        return chain.segments.count > 1
    }
```

**Step 3: Trigger chain loading when History tab is selected**

Find where `selectedTab` is set or where `.task(id:)` fires for the history tab. Add a chain load dispatch:

```swift
    // When History tab opens, ensure chain is loaded
    .task(id: card.id) {
        if store.state.chainByCardId[card.id] == nil {
            store.dispatch(.loadChain(cardId: card.id))
        }
    }
```

**Note:** This may already be inside an `.onAppear` or `.task` modifier. Integrate with the existing pattern rather than adding a duplicate.

**Step 4: Update `loadFullHistory()` to load from chain segments**

Replace the existing stub loop (line 1435) with actual chain paths:

```swift
    private func loadFullHistory() async {
        let paths = allSessionPaths
        guard !paths.isEmpty else { return }
        isLoadingHistory = true
        var allTurns: [ConversationTurn] = []

        for path in paths {
            if let turns = try? await TranscriptReader.readTurns(from: path) {
                allTurns.append(contentsOf: turns)
            }
        }

        // Re-index turns sequentially so scroll/search works correctly
        turns = allTurns.enumerated().map { idx, turn in
            ConversationTurn(
                index: idx, lineNumber: turn.lineNumber,
                role: turn.role, textPreview: turn.textPreview,
                timestamp: turn.timestamp, contentBlocks: turn.contentBlocks
            )
        }
        hasMoreTurns = false
        isLoadingHistory = false
    }
```

**Step 5: Run the app and test manually**

Run: `make deploy`
Test: Open a card that has multiple sessions in `session_links`. Verify:
- History tab loads turns from all recent sessions
- Turns are in chronological order

**Step 6: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "feat: history tab loads from session chain"
git push
```

---

## Task 9: History Tab — Session Dividers

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift`
- Modify: `Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift`

**Step 1: Write the failing test**

Add to `HistoryPlusHTMLBuilderTests.swift`:

```swift
    @Test("Session divider HTML is generated correctly")
    func sessionDividerHTML() {
        let divider = HistoryPlusHTMLBuilder.buildSessionDividerHTML(
            reason: "Resumed", gap: "2h gap", timestamp: "Mar 21, 14:30"
        )
        #expect(divider.contains("session-divider"))
        #expect(divider.contains("Resumed"))
        #expect(divider.contains("2h gap"))
        #expect(divider.contains("Mar 21, 14:30"))
    }

    @Test("Session divider without gap omits gap text")
    func sessionDividerNoGap() {
        let divider = HistoryPlusHTMLBuilder.buildSessionDividerHTML(
            reason: "Started", gap: nil, timestamp: "Mar 21, 09:00"
        )
        #expect(divider.contains("Started"))
        #expect(!divider.contains("gap"))
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter HistoryPlusHTMLBuilderTests 2>&1 | head -20`
Expected: FAIL — `buildSessionDividerHTML` not defined.

**Step 3: Implement session divider HTML generation**

Add to `HistoryPlusHTMLBuilder.swift`:

```swift
    /// Build HTML for a session transition divider.
    public static func buildSessionDividerHTML(reason: String, gap: String?, timestamp: String) -> String {
        var parts: [String] = [reason]
        if let gap { parts.append(gap) }
        parts.append(timestamp)
        let text = parts.joined(separator: " · ")

        return """
        <div class="session-divider">
            <span class="divider-line"></span>
            <span class="divider-text">\(escapeForAttribute(text))</span>
            <span class="divider-line"></span>
        </div>
        """
    }
```

Add to `chatCSS`:

```css
        .session-divider {
            display: flex;
            align-items: center;
            margin: 24px 0;
            gap: 12px;
        }
        .divider-line {
            flex: 1;
            height: 1px;
            background: rgba(98, 114, 164, 0.4);
        }
        .divider-text {
            color: rgba(98, 114, 164, 0.8);
            font-size: 0.8em;
            white-space: nowrap;
            font-style: italic;
        }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter HistoryPlusHTMLBuilderTests 2>&1 | tail -5`
Expected: PASS.

**Step 5: Wire dividers into HistoryPlusView**

Update `HistoryPlusHTMLBuilder.buildMessagesHTML` to accept an optional `sessionDividers` parameter — a dictionary of `[turnIndex: dividerHTML]`. Before each turn, check if a divider should be inserted.

Alternatively: have the caller (CardDetailView or HistoryPlusView) pre-calculate which turn indices correspond to session boundaries and inject divider turns into the conversation.

The cleanest approach: add a new variant to the `messagesHTML` builder that accepts `[(turns: [ConversationTurn], divider: String?)]` — an array of session groups. Each group gets a divider before its turns (except the first group if `.initial`).

**Step 6: Update CardDetailView to pass session boundary info to HistoryPlusView**

When building `turns` in `loadFullHistory()`, track which turn indices are session boundaries. Store as `@State private var sessionBoundaries: [(turnIndex: Int, dividerHTML: String)]`.

**Step 7: Commit**

```bash
git add Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift Tests/ClaudeBoardCoreTests/HistoryPlusHTMLBuilderTests.swift Sources/ClaudeBoard/CardDetailView.swift Sources/ClaudeBoard/HistoryPlusView.swift
git commit -m "feat: add session dividers to history timeline"
git push
```

---

## Task 10: Prompts Tab — WKWebView Markdown Rendering

**Files:**
- Modify: `Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift` (or create a shared builder)
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`

**Step 1: Add prompts HTML builder**

Add to `HistoryPlusHTMLBuilder.swift`:

```swift
    /// Build HTML for the prompts tab: user messages grouped by session with collapsible sections.
    public static func buildPromptsHTML(
        groups: [(sessionLabel: String, dividerHTML: String?, prompts: [ConversationTurn])]
    ) -> String {
        var parts: [String] = []

        for (i, group) in groups.enumerated() {
            if let divider = group.dividerHTML, i > 0 {
                parts.append(divider)
            }

            if groups.count > 1 {
                parts.append("""
                <details \(i == groups.count - 1 ? "open" : "")>
                    <summary class="session-header">\(escapeForAttribute(group.sessionLabel))</summary>
                """)
            }

            for prompt in group.prompts {
                let textBlocks = prompt.contentBlocks.filter { if case .text = $0.kind { true } else { false } }
                guard !textBlocks.isEmpty else { continue }
                let markdown = textBlocks.map(\.text).joined(separator: "\n\n")
                let escaped = escapeForAttribute(markdown)
                let ts = prompt.timestamp ?? ""
                let tsEscaped = escapeForAttribute(ts)

                parts.append("""
                <div class="prompt-entry">
                    <span class="prompt-ts">\(tsEscaped)</span>
                    <div class="prompt-body" data-md="\(escaped)"></div>
                </div>
                """)
            }

            if groups.count > 1 {
                parts.append("</details>")
            }
        }

        return parts.joined(separator: "\n")
    }

    /// CSS for prompts tab.
    public static let promptsCSS: String = """
        .session-header {
            color: rgba(98, 114, 164, 0.8);
            font-size: 0.85em;
            cursor: pointer;
            padding: 8px 0;
            font-style: italic;
        }
        .session-header:hover { color: rgba(139, 233, 253, 0.8); }
        details { margin: 8px 0; }
        .prompt-entry {
            padding: 12px 16px;
            border-bottom: 1px solid rgba(68, 71, 90, 0.5);
        }
        .prompt-ts {
            display: block;
            font-size: 0.75em;
            color: rgba(98, 114, 164, 0.6);
            font-family: monospace;
            margin-bottom: 6px;
        }
        .prompt-body {
            line-height: 1.6;
        }
        .prompt-body p { margin: 0.3em 0; }
        .prompt-body code {
            background: rgba(68, 71, 90, 0.5);
            padding: 2px 4px;
            border-radius: 3px;
            font-size: 0.9em;
        }
        .prompt-body pre {
            background: rgba(40, 42, 54, 0.8);
            padding: 12px;
            border-radius: 6px;
            overflow-x: auto;
        }
    """
```

**Step 2: Replace the plain-text prompts view with WKWebView**

In `CardDetailView.swift`, replace `promptTimelineView` (lines 927-1024) with a new WKWebView-based view. Create a `PromptsWebView` similar to `HistoryPlusView`:

```swift
struct PromptsWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadContent(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        guard html != coord.lastHTML else { return }
        loadContent(into: webView, coordinator: coord)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadContent(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastHTML = html
        let page = ReplyTabView.htmlPage(body: """
            <style>\(HistoryPlusHTMLBuilder.chatCSS)</style>
            <style>\(HistoryPlusHTMLBuilder.promptsCSS)</style>
            <div id="content">\(html)</div>
            <script>\(ReplyTabView.markedJs)</script>
            <script>\(HistoryPlusHTMLBuilder.renderScript)</script>
            """)
        webView.loadHTMLString(page, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other { return .allow }
            return .cancel
        }
    }
}
```

**Step 3: Update `loadPrompts()` to build grouped HTML**

```swift
    private func loadPrompts() async {
        guard store.state.chainByCardId[card.id] != nil || card.session?.jsonlPath != nil else {
            promptsHTML = ""
            return
        }
        guard promptsCardId != card.id else { return }
        isLoadingPrompts = true
        promptsCardId = card.id

        let paths = allSessionPaths
        let chain = store.state.chainByCardId[card.id]

        var groups: [(sessionLabel: String, dividerHTML: String?, prompts: [ConversationTurn])] = []

        for (i, path) in paths.enumerated() {
            var sessionPrompts: [ConversationTurn] = []
            for await turn in TranscriptReader.streamAllTurns(from: path) {
                if turn.role == "user" && !turn.textPreview.hasPrefix("[tool result") {
                    sessionPrompts.append(turn)
                }
            }

            let segment = chain?.segments[safe: i]
            let label = segment.map { formatSessionLabel($0) } ?? "Current session"
            let divider: String?
            if let seg = segment, i > 0 {
                divider = HistoryPlusHTMLBuilder.buildSessionDividerHTML(
                    reason: seg.transitionReason.label,
                    gap: seg.transitionReason.gapDescription,
                    timestamp: formatSegmentTimestamp(seg.firstTimestamp)
                )
            } else {
                divider = nil
            }

            groups.append((sessionLabel: label, dividerHTML: divider, prompts: sessionPrompts))
        }

        promptsHTML = HistoryPlusHTMLBuilder.buildPromptsHTML(groups: groups)
        // Keep promptTurns for count display and Copy All
        promptTurns = groups.flatMap(\.prompts)
        isLoadingPrompts = false
    }
```

Add a new `@State` property: `@State private var promptsHTML: String = ""`

Replace the `promptTimelineView` body to use `PromptsWebView(html: promptsHTML)`.

**Step 4: Keep the header (count + Copy All) and loading states**

The header with count and "Copy All" button stays as native SwiftUI above the `PromptsWebView`. Only the content area changes from plain `Text()` to the web view.

**Step 5: Deploy and test**

Run: `make deploy`
Test: Open a card's Prompts tab. Verify:
- User messages render as styled markdown with Dracula theme
- Multiple sessions show collapsible sections with dividers
- Copy All still works
- Count is correct

**Step 6: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift Sources/ClaudeBoardCore/UseCases/HistoryPlusHTMLBuilder.swift
git commit -m "feat: prompts tab with markdown rendering and session grouping"
git push
```

---

## Task 11: Load Earlier Sessions Button

**Files:**
- Modify: `Sources/ClaudeBoard/CardDetailView.swift`

**Step 1: Add "Load earlier sessions" to History tab**

At the top of the history scroll view, before the first turn, add:

```swift
    if let chain = store.state.chainByCardId[card.id], chain.hasMore {
        Button {
            let loaded = chain.segments.count
            store.dispatch(.loadChain(cardId: card.id, limit: loaded + 5))
        } label: {
            HStack {
                Image(systemName: "arrow.up.circle")
                Text("Load \(chain.totalSegments - chain.segments.count) earlier sessions")
            }
            .font(.app(.caption))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
```

**Step 2: Add same button to Prompts tab**

Similar button in the prompts header area.

**Step 3: Deploy and test**

Run: `make deploy`
Test: If a card has >5 sessions, verify the button appears and loads more.

**Step 4: Commit**

```bash
git add Sources/ClaudeBoard/CardDetailView.swift
git commit -m "feat: add load-earlier-sessions button to history and prompts tabs"
git push
```

---

## Task 12: Integration Test — End to End

**Files:**
- Test: `Tests/ClaudeBoardCoreTests/SessionChainTests.swift` (add integration test)

**Step 1: Write integration test**

```swift
    @Test("Full chain construction from DB rows and JSONL files")
    func fullChainConstruction() async throws {
        // Create temp JSONL files
        let dir = NSTemporaryDirectory() + "chain-integration-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path1 = (dir as NSString).appendingPathComponent("s1.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test","timestamp":"2026-01-01T10:00:00Z","slug":"my-slug"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi!"}]},"timestamp":"2026-01-01T10:30:00Z"}"#,
        ].joined(separator: "\n").write(toFile: path1, atomically: true, encoding: .utf8)

        let path2 = (dir as NSString).appendingPathComponent("s2.jsonl")
        try [
            #"{"type":"user","sessionId":"s2","message":{"content":"Continue"},"cwd":"/test","timestamp":"2026-01-01T14:00:00Z","slug":"my-slug"}"#,
            #"{"type":"assistant","sessionId":"s2","message":{"content":[{"type":"text","text":"Sure!"}]},"timestamp":"2026-01-01T14:15:00Z"}"#,
        ].joined(separator: "\n").write(toFile: path2, atomically: true, encoding: .utf8)

        // Build raw segments from JSONL files
        var rawSegments: [SessionChainBuilder.RawSegment] = []
        for (id, path) in [("s1", path1), ("s2", path2)] {
            let meta = try await TranscriptReader.readBoundaryMetadata(from: path)!
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            rawSegments.append(SessionChainBuilder.RawSegment(
                sessionId: id, path: path, matchedBy: "tmux",
                slug: meta.slug,
                firstTimestamp: iso.date(from: meta.firstTimestamp)!,
                lastTimestamp: iso.date(from: meta.lastTimestamp)!,
                lastLineText: meta.lastLineText
            ))
        }

        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: rawSegments, totalCount: 2)

        #expect(chain.segments.count == 2)
        #expect(chain.segments[0].id == "s1")
        #expect(chain.segments[0].transitionReason == .initial)
        // s2 shares slug "my-slug" with s1 → .resumed
        if case .resumed(let gap) = chain.segments[1].transitionReason {
            #expect(gap > 12000) // ~3.5h gap
        } else {
            Issue.record("Expected .resumed for same slug, got \(chain.segments[1].transitionReason)")
        }
    }
```

**Step 2: Run to verify it passes**

Run: `swift test --filter SessionChainTests 2>&1 | tail -5`
Expected: PASS.

**Step 3: Commit**

```bash
git add Tests/ClaudeBoardCoreTests/SessionChainTests.swift
git commit -m "test: add session chain integration test"
git push
```

---

## Task 13: Final Deploy & Manual Smoke Test

**Step 1: Full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass.

**Step 2: Deploy**

Run: `make deploy`

**Step 3: Manual smoke test checklist**

- [ ] Open a card with 1 session → History shows same as before, no dividers
- [ ] Open a card with 2+ sessions → History shows segmented timeline with dividers
- [ ] Divider text shows gap duration and timestamp
- [ ] Slug-matched sessions show "Resumed" label
- [ ] Sessions after Ctrl+C show "Interrupted" label
- [ ] Unknown transitions show "New session" label
- [ ] Search still works across sessions in History
- [ ] Prompts tab shows markdown-rendered user messages
- [ ] Prompts grouped by session with collapsible sections
- [ ] "Copy All" includes prompts from all sessions
- [ ] "Load earlier sessions" button appears when >5 sessions exist
- [ ] Live reload still works on the current session
- [ ] No crashes, no stale data after switching cards

**Step 4: Final commit if any cleanup needed**

```bash
git add -A
git commit -m "chore: final cleanup for session chain flow"
git push
```
