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

    @Test("Stop → immediate needsAttention")
    func stopImmediate() async {
        let detector = ClaudeCodeActivityDetector()
        let event = HookEvent(sessionId: "s1", eventName: "Stop")
        await detector.handleHookEvent(event)

        // Stop is immediate — no delay
        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)
    }

    @Test("Stop + follow-up prompt → activelyWorking")
    func stopThenPrompt() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))

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

    @Test("Resolve pending stops returns empty (Stop is immediate)")
    func resolvePendingStops() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s2", eventName: "Stop"))

        // Stop no longer creates pending stops — they resolve immediately
        let resolved = await detector.resolvePendingStops()
        #expect(resolved.count == 0)
    }

    @Test("UserPromptSubmit falls back to mtime check after grace period (handles Ctrl+C interrupt)")
    func interruptFallback() async {
        let detector = ClaudeCodeActivityDetector()

        // Simulate: UserPromptSubmit happened 5 seconds ago (past 3s grace period)
        let oldEvent = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-5)
        )
        await detector.handleHookEvent(oldEvent)

        // Create a file with old mtime (simulating Claude stopped writing)
        let dir = NSTemporaryDirectory() + "kanban-interrupt-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let oldDate = Date.now.addingTimeInterval(-30)
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)

        // Poll once so the detector knows the path
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        // activityState checks mtime directly — file is old, so not activelyWorking
        let state = await detector.activityState(for: "s1")
        #expect(state != .activelyWorking)
    }

    @Test("UserPromptSubmit stays activelyWorking within grace period")
    func activeWithinGracePeriod() async {
        let detector = ClaudeCodeActivityDetector()

        // Simulate: UserPromptSubmit happened 2 seconds ago (within 5s grace)
        let recentEvent = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-2)
        )
        await detector.handleHookEvent(recentEvent)

        // Even with an old file, trust the hook within grace period
        let dir = NSTemporaryDirectory() + "kanban-grace-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let oldDate = Date.now.addingTimeInterval(-30)
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("UserPromptSubmit stays activelyWorking when file is fresh")
    func activeWithFreshFile() async {
        let detector = ClaudeCodeActivityDetector()

        // Simulate: UserPromptSubmit 10 seconds ago, but file is still being written to
        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-10)
        )
        await detector.handleHookEvent(event)

        let dir = NSTemporaryDirectory() + "kanban-fresh-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        // File was just modified (now) — Claude is still writing
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
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
