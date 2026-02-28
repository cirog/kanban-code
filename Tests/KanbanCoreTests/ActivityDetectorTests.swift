import Testing
import Foundation
@testable import KanbanCore

@Suite("ActivityDetector")
struct ActivityDetectorTests {

    @Test("UserPromptSubmit → activelyWorking")
    func userPromptSubmit() async {
        let detector = ClaudeCodeActivityDetector()
        let event = HookEvent(sessionId: "s1", eventName: "UserPromptSubmit")
        await detector.handleHookEvent(event)
        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("Stop → needsAttention after delay")
    func stopAfterDelay() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0.05)
        let event = HookEvent(sessionId: "s1", eventName: "Stop")
        await detector.handleHookEvent(event)

        // Within delay window → still activelyWorking
        let immediate = await detector.activityState(for: "s1")
        #expect(immediate == .activelyWorking)

        // After delay → needsAttention
        try? await Task.sleep(for: .milliseconds(60))
        let delayed = await detector.activityState(for: "s1")
        #expect(delayed == .needsAttention)
    }

    @Test("Stop + follow-up prompt → stays activelyWorking")
    func stopThenPrompt() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0.05)
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))

        try? await Task.sleep(for: .milliseconds(60))
        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("SessionEnd → ended")
    func sessionEnd() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SessionEnd"))
        let state = await detector.activityState(for: "s1")
        #expect(state == .ended)
    }

    @Test("Unknown session → stale")
    func unknownSession() async {
        let detector = ClaudeCodeActivityDetector()
        let state = await detector.activityState(for: "unknown")
        #expect(state == .stale)
    }

    @Test("Notification → needsAttention")
    func notification() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Notification"))
        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)
    }

    @Test("Resolve pending stops returns expired sessions")
    func resolvePendingStops() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0.01)
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s2", eventName: "Stop"))

        try? await Task.sleep(for: .milliseconds(20))
        let resolved = await detector.resolvePendingStops()
        #expect(resolved.count == 2)
        #expect(resolved.contains("s1"))
        #expect(resolved.contains("s2"))
    }

    @Test("Poll activity detects recent modification as activelyWorking")
    func pollRecent() async {
        let dir = NSTemporaryDirectory() + "kanban-activity-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)

        let detector = ClaudeCodeActivityDetector()
        let states = await detector.pollActivity(sessionPaths: ["s1": path])
        #expect(states["s1"] == .activelyWorking)
    }
}
