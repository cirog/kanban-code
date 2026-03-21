import Testing
import Foundation
@testable import ClaudeBoardCore

// MARK: - Measurement Helper

/// Runs a block multiple times, computes the median duration in milliseconds,
/// and fails if it exceeds `limitMs`. Warmup iterations absorb one-time costs
/// (SQLite schema creation, filesystem cache priming).
@discardableResult
func measureMedian(
    iterations: Int = 10,
    limitMs: Double,
    warmup: Int = 1,
    block: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Double {
    // Warmup
    for _ in 0..<warmup {
        try await block()
    }

    // Measured iterations
    var durations: [Double] = []
    let clock = ContinuousClock()

    for _ in 0..<iterations {
        let elapsed = try await clock.measure {
            try await block()
        }
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        durations.append(ms)
    }

    durations.sort()
    let median = durations[durations.count / 2]
    let min = durations.first!
    let max = durations.last!

    #expect(
        median <= limitMs,
        "Median \(String(format: "%.2f", median))ms exceeds limit \(limitMs)ms (min=\(String(format: "%.2f", min)), max=\(String(format: "%.2f", max)))",
        sourceLocation: sourceLocation
    )

    return median
}

// MARK: - Performance Tests

@Suite("Performance")
struct PerformanceTests {

    static func makeTempDir(_ label: String = "perf") -> String {
        let dir = NSTemporaryDirectory() + "claudeboard-\(label)-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Fixture Generators

    static func makeLinks(_ count: Int) -> [Link] {
        let projects = ["/Users/test/project-a", "/Users/test/project-b",
                        "/Users/test/project-c", "/Users/test/project-d",
                        "/Users/test/project-e"]
        let columns: [ClaudeBoardColumn] = [.backlog, .inProgress, .waiting, .done]

        return (0..<count).map { i in
            Link(
                id: "card-\(i)",
                name: "Task \(i): implement feature for module \(i % 10)",
                projectPath: projects[i % projects.count],
                column: columns[i % columns.count],
                slug: "slug-\(i)",
                tmuxLink: TmuxLink(sessionName: "tmux-\(i)")
            )
        }
    }

    static func makeSettings() -> Settings {
        let projects = (0..<5).map { i in
            Project(path: "/Users/test/project-\(i)", name: "Project \(i)", color: "#\(String(format: "%06X", i * 111111))")
        }
        let labels = (0..<3).map { i in
            ProjectLabel(name: "Label \(i)", color: "#FF\(String(format: "%04X", i * 1000))")
        }
        return Settings(
            projects: projects,
            notifications: NotificationSettings(pushoverEnabled: true, pushoverToken: "tok_test", pushoverUserKey: "usr_test"),
            promptTemplate: "/orchestrate --mode fast",
            projectLabels: labels
        )
    }

    static func writeHookEvents(count: Int, to path: String) {
        let events = ["Stop", "UserPromptSubmit", "Notification"]
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        for i in 0..<count {
            let event = events[i % events.count]
            let ts = iso.string(from: Date.now.addingTimeInterval(Double(-count + i)))
            let line = #"{"sessionId":"session-\#(i % 20)","event":"\#(event)","timestamp":"\#(ts)","transcriptPath":"/tmp/s\#(i).jsonl"}"#
            lines.append(line)
        }
        try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func writeJsonlFile(turns: Int, to dir: String) -> String {
        let sessionId = UUID().uuidString
        let filePath = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
        var lines: [String] = []

        // First line: user message with metadata
        lines.append(#"{"type":"user","cwd":"/Users/test/project","slug":"test-slug","gitBranch":"main","message":{"role":"user","content":"Hello, help me implement a feature"},"timestamp":"2025-01-01T00:00:00Z"}"#)

        for i in 1..<turns {
            if i % 2 == 1 {
                // Assistant turn with content blocks
                lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here is my response for turn \#(i). Let me help you with that implementation. I'll start by reading the relevant files and understanding the codebase structure."},{"type":"tool_use","id":"tool_\#(i)","name":"Read","input":{"file_path":"/Users/test/src/main.swift"}}]},"timestamp":"2025-01-01T00:0\#(i):00Z"}"#)
            } else {
                // User turn
                lines.append(#"{"type":"user","message":{"role":"user","content":"Continue with the next step \#(i)"},"timestamp":"2025-01-01T00:0\#(i):00Z"}"#)
            }
        }

        try! lines.joined(separator: "\n").write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    static func populateClaudeDir(projects: Int, sessionsPerProject: Int, in baseDir: String) {
        for p in 0..<projects {
            let dirName = "-Users-test-project-\(p)"
            let dirPath = (baseDir as NSString).appendingPathComponent(dirName)
            try! FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

            var indexEntries: [[String: Any]] = []
            for s in 0..<sessionsPerProject {
                let sessionId = UUID().uuidString
                let filePath = (dirPath as NSString).appendingPathComponent("\(sessionId).jsonl")

                // Minimal 2-turn file to pass messageCount > 0 filter
                let content = """
                {"type":"user","cwd":"/Users/test/project-\(p)","slug":"slug-\(p)-\(s)","message":{"role":"user","content":"Task \(s)"},"timestamp":"2025-01-01T00:00:00Z"}
                {"type":"assistant","message":{"role":"assistant","content":"Working on it"},"timestamp":"2025-01-01T00:01:00Z"}
                """
                try! content.write(toFile: filePath, atomically: true, encoding: .utf8)

                indexEntries.append([
                    "sessionId": sessionId,
                    "summary": "Session \(s) for project \(p)"
                ])
            }

            // Write sessions-index.json
            let indexPath = (dirPath as NSString).appendingPathComponent("sessions-index.json")
            let indexData: [String: Any] = ["sessions": indexEntries]
            let jsonData = try! JSONSerialization.data(withJSONObject: indexData, options: .prettyPrinted)
            try! jsonData.write(to: URL(fileURLWithPath: indexPath))
        }
    }

    static func createSessionFiles(count: Int, in dir: String) -> [String: String] {
        var result: [String: String] = [:]
        for i in 0..<count {
            let sessionId = "session-\(i)"
            let filePath = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
            let content = #"{"type":"user","message":{"role":"user","content":"Hello \#(i)"}}"#
            try! content.write(toFile: filePath, atomically: true, encoding: .utf8)

            // Stagger mtimes so some are fresh and some are old
            let offset = TimeInterval(-i * 60)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(offset)],
                ofItemAtPath: filePath
            )
            result[sessionId] = filePath
        }
        return result
    }

    // MARK: - Group 1: CoordinationStore (SQLite)

    @Suite("CoordinationStore")
    struct CoordinationStorePerf {
        @Test("readLinks_100")
        func readLinks100() async throws {
            let dir = makeTempDir("coord-read")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)
            try await store.writeLinks(links)

            try await measureMedian(limitMs: 200) {
                _ = try await store.readLinks()
            }
        }

        @Test("writeLinks_100")
        func writeLinks100() async throws {
            let dir = makeTempDir("coord-write")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)

            try await measureMedian(limitMs: 250) {
                try await store.writeLinks(links)
            }
        }

        @Test("upsertLink_single")
        func upsertLinkSingle() async throws {
            let dir = makeTempDir("coord-upsert")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)
            try await store.writeLinks(links)

            var link = links[50]
            try await measureMedian(limitMs: 5) {
                link.name = "Updated \(Int.random(in: 0...10000))"
                try await store.upsertLink(link)
            }
        }

        @Test("linkById")
        func linkById() async throws {
            let dir = makeTempDir("coord-byid")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)
            try await store.writeLinks(links)

            try await measureMedian(limitMs: 3) {
                _ = try await store.linkById("card-50")
            }
        }

        @Test("linkForSession")
        func linkForSession() async throws {
            let dir = makeTempDir("coord-session")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)
            try await store.writeLinks(links)
            let sessionId = links[50].slug!

            try await measureMedian(limitMs: 5) {
                _ = try await store.linkForSession(sessionId)
            }
        }

        @Test("findBySlug")
        func findBySlug() async throws {
            let dir = makeTempDir("coord-slug")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)
            try await store.writeLinks(links)

            try await measureMedian(limitMs: 3) {
                _ = try await store.findBySlug("slug-50")
            }
        }

        @Test("removeLink")
        func removeLink() async throws {
            let dir = makeTempDir("coord-remove")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)
            try await store.writeLinks(links)

            try await measureMedian(limitMs: 10) {
                // Remove then re-insert so the next iteration has something to remove
                try await store.removeLink(id: "card-50")
                try await store.upsertLink(links[50])
            }
        }

        @Test("modifyLinks_100")
        func modifyLinks100() async throws {
            let dir = makeTempDir("coord-modify")
            defer { cleanup(dir) }
            let store = CoordinationStore(basePath: dir)
            let links = makeLinks(100)
            try await store.writeLinks(links)

            try await measureMedian(limitMs: 300) {
                try await store.modifyLinks { _ in }
            }
        }
    }

    // MARK: - Group 2: SettingsStore (JSON file)

    @Suite("SettingsStore")
    struct SettingsStorePerf {
        @Test("read_cached")
        func readCached() async throws {
            let dir = makeTempDir("settings-cached")
            defer { cleanup(dir) }
            let store = SettingsStore(basePath: dir)
            let settings = makeSettings()
            try await store.write(settings)
            // Prime the cache
            _ = try await store.read()

            try await measureMedian(limitMs: 1) {
                _ = try await store.read()
            }
        }

        @Test("read_uncached")
        func readUncached() async throws {
            let dir = makeTempDir("settings-uncached")
            defer { cleanup(dir) }
            let store = SettingsStore(basePath: dir)
            let settings = makeSettings()
            try await store.write(settings)

            try await measureMedian(limitMs: 10) {
                await store.invalidateCache()
                _ = try await store.read()
            }
        }

        @Test("write")
        func write() async throws {
            let dir = makeTempDir("settings-write")
            defer { cleanup(dir) }
            let store = SettingsStore(basePath: dir)
            let settings = makeSettings()

            try await measureMedian(limitMs: 10) {
                try await store.write(settings)
            }
        }
    }

    // MARK: - Group 3: HookEventStore (JSONL polling)

    @Suite("HookEventStore")
    struct HookEventStorePerf {
        @Test("readNewEvents_500")
        func readAllEvents500() async throws {
            let dir = makeTempDir("hook-all")
            defer { cleanup(dir) }
            // HookEventStore uses .claude-board basePath
            let filePath = (dir as NSString).appendingPathComponent("hook-events.jsonl")
            writeHookEvents(count: 500, to: filePath)
            let store = HookEventStore(basePath: dir)

            try await measureMedian(limitMs: 150) {
                _ = try await store.readAllEvents()
            }
        }

        @Test("readNewEvents_incremental")
        func readNewEventsIncremental() async throws {
            let dir = makeTempDir("hook-incr")
            defer { cleanup(dir) }
            let filePath = (dir as NSString).appendingPathComponent("hook-events.jsonl")
            writeHookEvents(count: 500, to: filePath)
            let store = HookEventStore(basePath: dir)

            // Read all first to set offset
            _ = try await store.readAllEvents()

            // Append 50 new lines
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            handle.seekToEndOfFile()
            let iso = ISO8601DateFormatter()
            var newLines = "\n"
            for i in 0..<50 {
                let ts = iso.string(from: .now)
                newLines += #"{"sessionId":"new-\#(i)","event":"Stop","timestamp":"\#(ts)"}"# + "\n"
            }
            handle.write(newLines.data(using: .utf8)!)
            try handle.close()

            try await measureMedian(limitMs: 5) {
                _ = try await store.readNewEvents()
            }
        }
    }

    // MARK: - Group 4: JsonlParser (static file parsing)

    @Suite("JsonlParser")
    struct JsonlParserPerf {
        @Test("extractMetadata_100turns")
        func extractMetadata100() async throws {
            let dir = makeTempDir("jsonl-100")
            defer { cleanup(dir) }
            let filePath = writeJsonlFile(turns: 100, to: dir)

            try await measureMedian(limitMs: 20) {
                _ = try await JsonlParser.extractMetadata(from: filePath)
            }
        }

        @Test("extractMetadata_earlyStop")
        func extractMetadataEarlyStop() async throws {
            let dir = makeTempDir("jsonl-1000")
            defer { cleanup(dir) }
            let filePath = writeJsonlFile(turns: 1000, to: dir)

            try await measureMedian(limitMs: 15) {
                _ = try await JsonlParser.extractMetadata(from: filePath)
            }
        }
    }

    // MARK: - Group 5: TranscriptReader (JSONL streaming)

    @Suite("TranscriptReader")
    struct TranscriptReaderPerf {
        @Test("readTail_last80")
        func readTailLast80() async throws {
            let dir = makeTempDir("transcript-tail")
            defer { cleanup(dir) }
            let filePath = writeJsonlFile(turns: 200, to: dir)

            try await measureMedian(limitMs: 50) {
                _ = try await TranscriptReader.readTail(from: filePath, maxTurns: 80)
            }
        }

        @Test("readTurns_200")
        func readTurns200() async throws {
            let dir = makeTempDir("transcript-all")
            defer { cleanup(dir) }
            let filePath = writeJsonlFile(turns: 200, to: dir)

            try await measureMedian(limitMs: 80) {
                _ = try await TranscriptReader.readTurns(from: filePath)
            }
        }
    }

    // MARK: - Group 6: SessionDiscovery (directory scanning)

    @Suite("SessionDiscovery")
    struct SessionDiscoveryPerf {
        @Test("discoverSessions_50files")
        func discoverSessions50() async throws {
            let dir = makeTempDir("discovery-50")
            defer { cleanup(dir) }
            populateClaudeDir(projects: 5, sessionsPerProject: 10, in: dir)
            let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)

            try await measureMedian(limitMs: 500) {
                _ = try await discovery.discoverSessions()
            }
        }

        @Test("discoverSessions_cached")
        func discoverSessionsCached() async throws {
            let dir = makeTempDir("discovery-cached")
            defer { cleanup(dir) }
            populateClaudeDir(projects: 5, sessionsPerProject: 10, in: dir)
            let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)

            // Prime the cache
            _ = try await discovery.discoverSessions()

            try await measureMedian(limitMs: 30) {
                _ = try await discovery.discoverSessions()
            }
        }
    }

    // MARK: - Group 7: ActivityDetector (file mtime polling)

    @Suite("ActivityDetector")
    struct ActivityDetectorPerf {
        @Test("pollActivity_50sessions")
        func pollActivity50() async throws {
            let dir = makeTempDir("activity-50")
            defer { cleanup(dir) }
            let sessionFiles = createSessionFiles(count: 50, in: dir)
            let detector = ClaudeCodeActivityDetector()

            try await measureMedian(limitMs: 30) {
                _ = await detector.pollActivity(sessionPaths: sessionFiles)
            }
        }
    }
}
