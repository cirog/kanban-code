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
