import Foundation

/// Reads sessions-index.json files from Claude's project directories.
public enum SessionIndexReader {

    /// An entry from sessions-index.json.
    public struct IndexEntry: Sendable {
        public let sessionId: String
        public let summary: String?
        public let projectPath: String
        public let directoryName: String
    }

    /// Read all index entries from a sessions-index.json file.
    public static func readIndex(at path: String, directoryName: String) throws -> [IndexEntry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let projectPath = JsonlParser.decodeDirectoryName(directoryName)
        var entries: [IndexEntry] = []

        // sessions-index.json has various formats; handle the common ones
        // Format 1: { "sessions": [ { "sessionId": "...", "summary": "..." } ] }
        if let sessions = root["sessions"] as? [[String: Any]] {
            for session in sessions {
                guard let sessionId = session["sessionId"] as? String else { continue }
                let summary = session["summary"] as? String
                entries.append(IndexEntry(
                    sessionId: sessionId,
                    summary: summary,
                    projectPath: projectPath,
                    directoryName: directoryName
                ))
            }
        }

        // Format 2: top-level keys are session IDs
        // { "uuid-1": { "summary": "..." }, "uuid-2": { ... } }
        if entries.isEmpty {
            for (key, value) in root {
                // Skip non-UUID-looking keys
                guard key.count >= 32, key.contains("-") else { continue }
                let summary: String?
                if let dict = value as? [String: Any] {
                    summary = dict["summary"] as? String
                } else {
                    summary = nil
                }
                entries.append(IndexEntry(
                    sessionId: key,
                    summary: summary,
                    projectPath: projectPath,
                    directoryName: directoryName
                ))
            }
        }

        return entries
    }
}
