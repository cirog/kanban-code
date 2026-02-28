import Foundation

/// Implements SessionStore for Claude Code .jsonl files.
public final class ClaudeCodeSessionStore: SessionStore, @unchecked Sendable {

    public init() {}

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        try await TranscriptReader.readTurns(from: sessionPath)
    }

    public func forkSession(sessionPath: String) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let newSessionId = UUID().uuidString
        let dir = (sessionPath as NSString).deletingLastPathComponent
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
        let queryTerms = BM25Scorer.tokenize(query)
        guard !queryTerms.isEmpty else { return [] }

        // First pass: collect document stats
        struct DocInfo {
            let path: String
            let tokens: [String]
            let snippet: String
            let modifiedTime: Date
        }

        var docs: [DocInfo] = []
        var globalTermFreqs: [String: Int] = [:]
        var totalTokenCount = 0

        let fileManager = FileManager.default

        // Filter to existing files and sort by modification time (newest first)
        let validPaths: [(String, Date)] = paths.compactMap { path in
            guard fileManager.fileExists(atPath: path),
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }.sorted { $0.1 > $1.1 }

        // Limit to most recent 50 files to keep search responsive
        let searchPaths = validPaths.prefix(50)

        for (path, mtime) in searchPaths {
            guard !Task.isCancelled else { break }

            // Read file as Data (much faster than AsyncBytes line-by-line)
            let textParts = readTextParts(from: path)

            let fullText = textParts.joined(separator: " ")
            guard !fullText.isEmpty else { continue }

            let tokens = BM25Scorer.tokenize(fullText)

            // Track document frequencies
            let uniqueTokens = Set(tokens)
            for token in uniqueTokens {
                globalTermFreqs[token, default: 0] += 1
            }
            totalTokenCount += tokens.count

            // Find best snippet
            let snippet = findBestSnippet(text: fullText, queryTerms: queryTerms)

            docs.append(DocInfo(path: path, tokens: tokens, snippet: snippet, modifiedTime: mtime))

            // Yield to avoid blocking
            await Task.yield()
        }

        guard !docs.isEmpty else { return [] }
        let avgDocLength = Double(totalTokenCount) / Double(docs.count)

        // Score each document
        var results: [SearchResult] = []
        for doc in docs {
            let boost = BM25Scorer.recencyBoost(modifiedTime: doc.modifiedTime)
            let score = BM25Scorer.score(
                terms: queryTerms,
                documentTokens: doc.tokens,
                avgDocLength: avgDocLength,
                docCount: docs.count,
                docFreqs: globalTermFreqs,
                recencyBoost: boost
            )
            if score > 0 {
                results.append(SearchResult(sessionPath: doc.path, score: score, snippet: doc.snippet))
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// Read text parts from a .jsonl file using synchronous Data loading (fast).
    private func readTextParts(from path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        // Limit to first 500KB of text to avoid huge files
        let limit = 500_000
        let searchContent = content.count > limit ? String(content.prefix(limit)) : content

        var textParts: [String] = []
        for line in searchContent.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"type\"") else { continue }
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            if type == "user" || type == "assistant" {
                if let text = JsonlParser.extractTextContent(from: obj) {
                    textParts.append(text)
                }
            }
        }
        return textParts
    }

    /// Find the best snippet containing query terms.
    private func findBestSnippet(text: String, queryTerms: [String]) -> String {
        let lower = text.lowercased()
        var bestStart = 0
        var bestScore = 0

        // Sliding window approach
        let windowSize = 200
        let step = 50

        var offset = 0
        while offset < lower.count {
            let startIdx = lower.index(lower.startIndex, offsetBy: offset, limitedBy: lower.endIndex) ?? lower.endIndex
            let endIdx = lower.index(startIdx, offsetBy: windowSize, limitedBy: lower.endIndex) ?? lower.endIndex
            let window = String(lower[startIdx..<endIdx])

            var score = 0
            for term in queryTerms {
                if window.contains(term) { score += 1 }
            }

            if score > bestScore {
                bestScore = score
                bestStart = offset
            }

            offset += step
        }

        // Extract the snippet from original text
        let startIdx = text.index(text.startIndex, offsetBy: bestStart, limitedBy: text.endIndex) ?? text.endIndex
        let endIdx = text.index(startIdx, offsetBy: windowSize, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[startIdx..<endIdx])
        if bestStart > 0 { snippet = "..." + snippet }
        if endIdx < text.endIndex { snippet += "..." }

        return snippet
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
