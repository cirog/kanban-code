import Testing
@testable import KanbanCodeCore

struct TerminalOverlayTests {
    @Test("Tracks sessions and active session")
    func tracksSessions() {
        var state = TerminalOverlayState()
        let changed = state.update(sessions: ["s1", "s2"], active: "s1", frame: .zero)
        #expect(changed)
        #expect(state.sessions == ["s1", "s2"])
        #expect(state.activeSession == "s1")
    }

    @Test("Detects no change when state unchanged")
    func detectsNoChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1"], active: "s1", frame: .zero)
        let changed = state.update(sessions: ["s1"], active: "s1", frame: .zero)
        #expect(!changed)
    }

    @Test("Detects session change")
    func detectsSessionChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1"], active: "s1", frame: .zero)
        let changed = state.update(sessions: ["s1", "s2"], active: "s1", frame: .zero)
        #expect(changed)
    }

    @Test("Detects active session change")
    func detectsActiveChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1", "s2"], active: "s1", frame: .zero)
        let changed = state.update(sessions: ["s1", "s2"], active: "s2", frame: .zero)
        #expect(changed)
    }

    @Test("Detects frame change")
    func detectsFrameChange() {
        var state = TerminalOverlayState()
        let _ = state.update(sessions: ["s1"], active: "s1", frame: .init(x: 0, y: 0, width: 100, height: 100))
        let changed = state.update(sessions: ["s1"], active: "s1", frame: .init(x: 0, y: 0, width: 200, height: 100))
        #expect(changed)
    }
}
