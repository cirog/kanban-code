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

    @Test("Full chain construction from JSONL files")
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

        let path3 = (dir as NSString).appendingPathComponent("s3.jsonl")
        try [
            #"{"type":"user","sessionId":"s3","message":{"content":"New topic"},"cwd":"/test","timestamp":"2026-01-02T09:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s3","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-01-02T09:10:00Z"}"#,
        ].joined(separator: "\n").write(toFile: path3, atomically: true, encoding: .utf8)

        let path4 = (dir as NSString).appendingPathComponent("s4.jsonl")
        try [
            #"{"type":"user","sessionId":"s4","message":{"content":"After interrupt"},"cwd":"/test","timestamp":"2026-01-02T09:15:00Z"}"#,
            #"{"type":"assistant","sessionId":"s4","message":{"content":[{"type":"text","text":"Continuing"}]},"timestamp":"2026-01-02T09:30:00Z"}"#,
        ].joined(separator: "\n").write(toFile: path4, atomically: true, encoding: .utf8)

        // Build raw segments from JSONL files
        var rawSegments: [SessionChainBuilder.RawSegment] = []
        for (id, path) in [("s1", path1), ("s2", path2), ("s3", path3), ("s4", path4)] {
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

        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: rawSegments, totalCount: 4)

        // Verify ordering
        #expect(chain.segments.count == 4)
        #expect(chain.segments.map(\.id) == ["s1", "s2", "s3", "s4"])

        // s1: first in chain
        #expect(chain.segments[0].transitionReason == .initial)

        // s2: same slug "my-slug" as s1 → .resumed
        if case .resumed(let gap) = chain.segments[1].transitionReason {
            #expect(gap > 12000) // ~3.5h gap
        } else {
            Issue.record("Expected .resumed for same slug, got \(chain.segments[1].transitionReason)")
        }

        // s3: no slug, different from s2's slug → .newSession
        if case .newSession = chain.segments[2].transitionReason {
            // correct
        } else {
            Issue.record("Expected .newSession, got \(chain.segments[2].transitionReason)")
        }

        // s4: s3 ended with interrupted text → .interrupted
        if case .interrupted(let gap) = chain.segments[3].transitionReason {
            #expect(gap == 300) // 5 min gap
        } else {
            Issue.record("Expected .interrupted, got \(chain.segments[3].transitionReason)")
        }

        // Verify no pagination
        #expect(chain.hasMore == false)
    }
}
