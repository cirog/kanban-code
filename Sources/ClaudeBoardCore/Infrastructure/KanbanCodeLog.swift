import Foundation

/// Centralized logging for ClaudeBoard — writes to ~/.kanban-code/logs/kanban-code.log.
/// Thread-safe, fire-and-forget. Use from anywhere in ClaudeBoardCore or ClaudeBoard.
public enum ClaudeBoardLog {

    private static let logDir: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let logPath: String = {
        (logDir as NSString).appendingPathComponent("kanban-code.log")
    }()

    private static let rotatedPath: String = {
        (logDir as NSString).appendingPathComponent("kanban-code.log.1")
    }()

    private static let queue = DispatchQueue(label: "kanban-code.log", qos: .utility)

    /// Reusable formatter — ISO8601DateFormatter init is expensive (ICU setup).
    /// Accessed only inside `queue.async` blocks — serial access, safe despite non-Sendable type.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    /// Persistent file handle — opened once, reused for all writes.
    private nonisolated(unsafe) static var handle: FileHandle?

    /// Maximum log size before rotation (10 MB).
    private static let maxSize: UInt64 = 10 * 1024 * 1024

    /// Log a message with a subsystem tag.
    /// Example: `ClaudeBoardLog.info("reconciler", "Matched session \(id) to card \(cardId)")`
    public nonisolated static func info(_ subsystem: String, _ message: String) {
        write("INFO", subsystem, message)
    }

    /// Log a warning.
    public nonisolated static func warn(_ subsystem: String, _ message: String) {
        write("WARN", subsystem, message)
    }

    /// Log an error.
    public nonisolated static func error(_ subsystem: String, _ message: String) {
        write("ERROR", subsystem, message)
    }

    private nonisolated static func write(_ level: String, _ subsystem: String, _ message: String) {
        queue.async {
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] [\(subsystem)] \(message)\n"

            // Open handle if needed
            if handle == nil {
                rotateIfNeeded()
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                handle = FileHandle(forWritingAtPath: logPath)
                handle?.seekToEndOfFile()
            }

            guard let h = handle, let data = line.data(using: .utf8) else { return }
            h.write(data)

            // Check size — cheap on an open fd (just reads the offset)
            if h.offsetInFile > maxSize {
                h.closeFile()
                handle = nil
                rotateIfNeeded()
            }
        }
    }

    /// Rotate: delete .1, move current → .1.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logPath),
              let attrs = try? fm.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64,
              size > maxSize else { return }

        try? fm.removeItem(atPath: rotatedPath)
        try? fm.moveItem(atPath: logPath, toPath: rotatedPath)
    }
}
