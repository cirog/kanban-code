import Foundation

/// Reads and manages hook events from ~/.claude-board/hook-events.jsonl.
public actor HookEventStore {
    private let filePath: String
    private var lastReadOffset: UInt64 = 0

    /// Cached events for the reconciler — incrementally updated via readAllStoredEvents().
    private var cachedEvents: [HookEvent] = []
    private var cachedOffset: UInt64 = 0

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-board")
        self.filePath = (base as NSString).appendingPathComponent("hook-events.jsonl")
    }

    /// Read new events since the last read (for notification processing).
    public func readNewEvents() throws -> [HookEvent] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        handle.seek(toFileOffset: lastReadOffset)
        let data = handle.readDataToEndOfFile()
        lastReadOffset = handle.offsetInFile

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        return Self.parseEvents(from: text)
    }

    /// Read all events incrementally — caches previously parsed events and only
    /// parses new data appended since the last call. Called every 5s by the reconciler.
    public func readAllStoredEvents() throws -> [HookEvent] {
        guard FileManager.default.fileExists(atPath: filePath) else { return cachedEvents }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        // File was truncated/rotated — re-read from start
        let fileSize = handle.seekToEndOfFile()
        if fileSize < cachedOffset {
            cachedEvents = []
            cachedOffset = 0
        }

        guard fileSize > cachedOffset else { return cachedEvents }

        handle.seek(toFileOffset: cachedOffset)
        let data = handle.readDataToEndOfFile()
        cachedOffset = handle.offsetInFile

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return cachedEvents }
        let newEvents = Self.parseEvents(from: text)
        cachedEvents.append(contentsOf: newEvents)
        return cachedEvents
    }

    private static func parseEvents(from text: String) -> [HookEvent] {
        let iso = ISO8601DateFormatter()
        return text.components(separatedBy: "\n").compactMap { line -> HookEvent? in
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = obj["sessionId"] as? String else { return nil }
            let tmuxSession = obj["tmuxSession"] as? String
            return HookEvent(
                sessionId: sessionId,
                eventName: obj["event"] as? String ?? "unknown",
                transcriptPath: obj["transcriptPath"] as? String,
                tmuxSessionName: tmuxSession?.isEmpty == true ? nil : tmuxSession,
                pid: obj["pid"] as? Int,
                timestamp: (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            )
        }
    }

    /// The file path.
    public var path: String { filePath }
}
