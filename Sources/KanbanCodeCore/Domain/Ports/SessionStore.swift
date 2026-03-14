import Foundation

/// Port for reading and modifying Claude Code session files.
public protocol SessionStore: Sendable {
    /// Read conversation turns from a session file.
    func readTranscript(sessionPath: String) async throws -> [ConversationTurn]

    /// Fork (duplicate) a session, returning the new session ID.
    /// If targetDirectory is provided, the fork is placed there instead of the original directory.
    func forkSession(sessionPath: String, targetDirectory: String?) async throws -> String

    /// Truncate a session to a given turn (checkpoint). Creates a .bkp backup.
    func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws

    /// Write conversation turns to a new session file in this store's native format.
    /// Returns the path to the new session file.
    func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String
}

extension SessionStore {
    public func forkSession(sessionPath: String) async throws -> String {
        try await forkSession(sessionPath: sessionPath, targetDirectory: nil)
    }

    /// Default: writing is not supported.
    public func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String {
        throw SessionStoreError.writeNotSupported
    }
}
