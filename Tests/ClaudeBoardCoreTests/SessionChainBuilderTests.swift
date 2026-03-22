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

    @Test("First segment gets .initial transition reason")
    func firstIsInitial() {
        let raw = [makeRawSegment(sessionId: "s1", path: "/s1.jsonl", firstTimestamp: .now)]
        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 1)
        #expect(chain.segments[0].transitionReason == .initial)
    }

    @Test("Same slug as previous → .resumed with correct gap")
    func resumedBySameSlug() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t1End = Date(timeIntervalSince1970: 2000)
        let t2 = Date(timeIntervalSince1970: 5600)

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
        let t2 = Date(timeIntervalSince1970: 2300)

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
            // correct
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

    @Test("totalCount reflects pagination")
    func paginationTotal() {
        let raw = [makeRawSegment(sessionId: "s1", path: "/s1.jsonl", firstTimestamp: .now)]
        let chain = SessionChainBuilder.build(cardId: "card-1", rawSegments: raw, totalCount: 8)
        #expect(chain.totalSegments == 8)
        #expect(chain.hasMore == true)
    }
}
