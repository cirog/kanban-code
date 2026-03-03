import Foundation

/// Implements SessionStore for Claude Code .jsonl files.
public final class ClaudeCodeSessionStore: SessionStore, @unchecked Sendable {

    public init() {}

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        try await TranscriptReader.readTurns(from: sessionPath)
    }

    public func forkSession(sessionPath: String, targetDirectory: String? = nil) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let newSessionId = UUID().uuidString.lowercased()
        let dir = targetDirectory ?? (sessionPath as NSString).deletingLastPathComponent
        if let targetDirectory, !fileManager.fileExists(atPath: targetDirectory) {
            try fileManager.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
        }
        let newPath = (dir as NSString).appendingPathComponent("\(newSessionId).jsonl")

        // Read, replace session IDs, write
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let oldSessionId = (sessionPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")

        var lines: [String] = []
        for try await line in handle.bytes.lines {
            let replaced = line.replacingOccurrences(
                of: "\"\(oldSessionId)\"",
                with: "\"\(newSessionId)\""
            )
            lines.append(replaced)
        }

        try lines.joined(separator: "\n").write(
            toFile: newPath, atomically: true, encoding: .utf8
        )

        // Preserve the original file's mtime so the activity detector
        // doesn't treat the fork as "actively working" (10-second window).
        if let attrs = try? fileManager.attributesOfItem(atPath: sessionPath),
           let originalMtime = attrs[.modificationDate] as? Date {
            try? fileManager.setAttributes(
                [.modificationDate: originalMtime],
                ofItemAtPath: newPath
            )
        }

        return newSessionId
    }

    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        // Backup
        let backupPath = sessionPath + ".bkp"
        try? fileManager.removeItem(atPath: backupPath)
        try fileManager.copyItem(atPath: sessionPath, toPath: backupPath)

        // Read lines up to the target line number
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var keptLines: [String] = []
        var lineNumber = 0

        for try await line in handle.bytes.lines {
            lineNumber += 1
            keptLines.append(line)
            if lineNumber >= afterTurn.lineNumber {
                break
            }
        }

        try keptLines.joined(separator: "\n").write(
            toFile: sessionPath, atomically: true, encoding: .utf8
        )
    }

    public func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        let box = ResultBox()
        try await searchSessionsStreaming(query: query, paths: paths) { results in
            box.results = results
        }
        return box.results
    }

    /// Thread-safe box to capture streaming results for the batch API.
    private final class ResultBox: @unchecked Sendable {
        var results: [SearchResult] = []
    }

    public func searchSessionsStreaming(
        query: String, paths: [String],
        onResult: @MainActor @Sendable ([SearchResult]) -> Void
    ) async throws {
        let t0 = ContinuousClock.now
        let queryTerms = BM25Scorer.tokenize(query)
        guard !queryTerms.isEmpty else { return }

        struct DocInfo {
            let path: String
            let matchingTokens: [String]
            let wordCount: Int
            let snippets: [String]
            let modifiedTime: Date
        }

        var docs: [DocInfo] = []
        var globalTermFreqs: [String: Int] = [:]
        var totalWordCount = 0

        let fileManager = FileManager.default

        // Filter to existing files and sort by modification time (newest first)
        let validPaths: [(String, Date)] = paths.compactMap { path in
            guard fileManager.fileExists(atPath: path),
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }.sorted { $0.1 > $1.1 }

        KanbanCodeLog.info("search", "searchSessions: \(validPaths.count)/\(paths.count) valid files, terms=\(queryTerms)")

        for (idx, (path, mtime)) in validPaths.enumerated() {
            try Task.checkCancellation()

            let tFile = ContinuousClock.now
            let (matchingTokens, wordCount, snippets) = try await extractMatchingTokens(
                from: path, queryTerms: queryTerms
            )
            let fileName = (path as NSString).lastPathComponent
            if idx < 5 || idx % 20 == 0 {
                let fileSize = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                KanbanCodeLog.info("search", "  [\(idx+1)/\(validPaths.count)] \(fileName) (\(fileSize / 1024)KB) words=\(wordCount) matches=\(matchingTokens.count) \(tFile.duration(to: .now))")
            }
            guard wordCount > 0 else { continue }

            totalWordCount += wordCount

            // Only track and yield when file has matching tokens
            guard !matchingTokens.isEmpty else { continue }

            // Track global document frequencies
            let uniqueTerms = Set(matchingTokens)
            for term in uniqueTerms {
                globalTermFreqs[term, default: 0] += 1
            }

            docs.append(DocInfo(
                path: path,
                matchingTokens: matchingTokens,
                wordCount: wordCount,
                snippets: snippets,
                modifiedTime: mtime
            ))

            // Score all matching docs with running stats and yield immediately
            let avgDocLength = Double(totalWordCount) / max(Double(docs.count), 1.0)
            var results: [SearchResult] = []
            for doc in docs {
                let boost = BM25Scorer.recencyBoost(modifiedTime: doc.modifiedTime)
                let score = BM25Scorer.score(
                    terms: queryTerms,
                    documentTokens: doc.matchingTokens,
                    avgDocLength: avgDocLength,
                    docCount: docs.count,
                    docFreqs: globalTermFreqs,
                    recencyBoost: boost
                )
                if score > 0 {
                    results.append(SearchResult(sessionPath: doc.path, score: score, snippets: doc.snippets))
                }
            }
            results.sort { $0.score > $1.score }
            await onResult(results)
        }

        KanbanCodeLog.info("search", "searchSessions DONE: \(docs.count) docs in \(t0.duration(to: .now))")
    }

    /// Stream through a .jsonl file line-by-line, extracting only tokens that match query terms.
    /// Returns (matchingTokens, totalWordCount, snippets).
    /// Streams via FileHandle — never loads the entire file into memory.
    /// Throws CancellationError if the task is cancelled mid-file.
    private static let maxSnippets = 3

    private func extractMatchingTokens(
        from path: String,
        queryTerms: [String]
    ) async throws -> (tokens: [String], wordCount: Int, snippets: [String]) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ([], 0, [])
        }
        defer { try? handle.close() }

        var matchingTokens: [String] = []
        var wordCount = 0
        // Track top snippets sorted by score (number of matching query terms)
        var topSnippets: [(score: Int, text: String)] = []
        var lineCount = 0

        for try await line in handle.bytes.lines {
            // Check cancellation every 100 lines to stay responsive
            lineCount += 1
            if lineCount % 100 == 0 {
                try Task.checkCancellation()
            }

            // Fast string check — skip lines that aren't user/assistant messages
            guard line.contains("\"type\"") else { continue }
            guard line.contains("\"user\"") || line.contains("\"assistant\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let text = JsonlParser.extractTextContent(from: obj) else { continue }

            // Tokenize and match — only keep tokens that match query terms
            let docTokens = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count >= 2 }

            wordCount += docTokens.count

            for token in docTokens {
                if let matched = matchQueryTerm(token: token, queryTerms: queryTerms) {
                    matchingTokens.append(matched)
                }
            }

            // Track top snippets by number of matching query terms
            let lower = text.lowercased()
            var snippetScore = 0
            for qt in queryTerms {
                if lower.contains(qt) { snippetScore += 1 }
            }
            if snippetScore > 0 {
                let snippet = extractSnippet(from: text, queryTerms: queryTerms, role: type)
                // Insert if we have room or this scores higher than the worst
                if topSnippets.count < Self.maxSnippets {
                    topSnippets.append((snippetScore, snippet))
                    topSnippets.sort { $0.score > $1.score }
                } else if snippetScore > topSnippets.last!.score {
                    topSnippets[topSnippets.count - 1] = (snippetScore, snippet)
                    topSnippets.sort { $0.score > $1.score }
                }
            }
        }

        return (matchingTokens, wordCount, topSnippets.map(\.text))
    }

    /// Check if a document token matches any query term (exact or prefix match).
    private func matchQueryTerm(token: String, queryTerms: [String]) -> String? {
        for qt in queryTerms {
            if token == qt || token.hasPrefix(qt) || qt.hasPrefix(token) {
                return qt  // normalize to query term for TF counting
            }
        }
        return nil
    }

    /// Extract a snippet around the first query term match in text.
    private func extractSnippet(from text: String, queryTerms: [String], role: String) -> String {
        let lower = text.lowercased()
        for qt in queryTerms {
            if let range = lower.range(of: qt) {
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let start = max(0, idx - 40)
                let end = min(text.count, idx + qt.count + 60)
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(text.startIndex, offsetBy: end)
                let prefix = start > 0 ? "..." : ""
                let suffix = end < text.count ? "..." : ""
                let snippet = text[startIdx..<endIdx].replacingOccurrences(of: "\n", with: " ")
                let label = role == "user" ? "You" : "Claude"
                return "\(label): \(prefix)\(snippet)\(suffix)"
            }
        }
        return String(text.prefix(100))
    }
}

public enum SessionStoreError: Error, LocalizedError {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): "Session file not found: \(path)"
        }
    }
}
