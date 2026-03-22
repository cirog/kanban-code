import Foundation

/// Executes side effects produced by the Reducer.
/// All async operations (disk, network, tmux) go through here.
public actor EffectHandler {
    private let coordinationStore: CoordinationStore
    private let tmuxAdapter: TmuxManagerPort?
    public init(
        coordinationStore: CoordinationStore,
        tmuxAdapter: TmuxManagerPort? = nil
    ) {
        self.coordinationStore = coordinationStore
        self.tmuxAdapter = tmuxAdapter
    }

    public func execute(_ effect: Effect, dispatch: @MainActor @Sendable (Action) -> Void) async {
        switch effect {
        case .persistLinks(let links, let associations):
            do {
                try await coordinationStore.writeLinks(links, associations: associations)
            } catch {
                ClaudeBoardLog.warn("effect", "persistLinks failed: \(error)")
            }

        case .upsertLink(let link):
            do {
                try await coordinationStore.upsertLink(link)
            } catch {
                ClaudeBoardLog.warn("effect", "upsertLink failed: \(error)")
            }

        case .removeLink(let id):
            do {
                try await coordinationStore.removeLink(id: id)
            } catch {
                ClaudeBoardLog.warn("effect", "removeLink failed: \(error)")
            }

        case .createTmuxSession(let cardId, let name, let path):
            do {
                try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
                await dispatch(.terminalCreated(cardId: cardId, tmuxName: name))
            } catch {
                await dispatch(.terminalFailed(cardId: cardId, error: error.localizedDescription))
            }

        case .killTmuxSession(let name):
            try? await tmuxAdapter?.killSession(name: name)

        case .killTmuxSessions(let names):
            for name in names {
                try? await tmuxAdapter?.killSession(name: name)
            }

        case .deleteSessionFile(let path):
            try? FileManager.default.removeItem(atPath: path)

        case .cleanupTerminalCache(let sessionNames):
            await MainActor.run {
                for name in sessionNames {
                    TerminalCacheRelay.remove(name)
                }
            }

        case .refreshDiscovery:
            // This is handled by the orchestrator, not here
            break

        case .updateSessionIndex(let sessionId, let name):
            try? SessionIndexReader.updateSummary(sessionId: sessionId, summary: name)

        case .moveSessionFile(let cardId, let sessionId, let oldPath, let newProjectPath):
            do {
                let newPath = try SessionFileMover.moveSession(
                    sessionId: sessionId,
                    fromPath: oldPath,
                    toProjectPath: newProjectPath
                )
                // Update the session path in session_links table
                try await coordinationStore.linkSession(
                    sessionId: sessionId, linkId: cardId,
                    matchedBy: "move", path: newPath
                )
                ClaudeBoardLog.info("effect", "Moved session \(sessionId.prefix(8)) → \(newPath)")
            } catch {
                ClaudeBoardLog.warn("effect", "moveSessionFile failed: \(error)")
                await dispatch(.setError("Move failed: \(error.localizedDescription)"))
            }
        case .sendPromptToTmux(let sessionName, let promptBody, let assistant):
            do {
                try await tmuxAdapter?.sendPrompt(to: sessionName, text: promptBody)
            } catch {
                ClaudeBoardLog.warn("effect", "sendPromptToTmux failed: \(error)")
            }

        case .sendPromptWithImagesToTmux(let sessionName, let promptBody, let imagePaths, _):
            do {
                try await tmuxAdapter?.sendPrompt(to: sessionName, text: promptBody)
                for path in imagePaths {
                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                ClaudeBoardLog.warn("effect", "sendPromptWithImagesToTmux failed: \(error)")
            }

        case .deleteFiles(let paths):
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }

        case .completeTodoistTask(let todoistId):
            do {
                try await TodoistAdapter.completeTask(id: todoistId)
                ClaudeBoardLog.info("todoist", "Completed task \(todoistId)")
            } catch {
                ClaudeBoardLog.warn("todoist", "Failed to complete task \(todoistId): \(error)")
                await dispatch(.setError("Todoist: failed to complete task \(todoistId): \(error.localizedDescription)"))
            }

        case .killClaudeProcess(let sessionId):
            await Self.killClaudeProcess(sessionId: sessionId)

        case .loadChain:
            break // TODO: Task 6 — EffectHandler chain loading
        }
    }

    /// Find and kill any `claude` CLI process whose arguments contain the given session ID.
    private static func killClaudeProcess(sessionId: String) async {
        do {
            let result = try await ShellCommand.run("/bin/ps", arguments: ["ax", "-o", "pid=,args="])
            let lines = result.stdout.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("claude") && trimmed.contains(sessionId) else { continue }
                // Extract PID (first whitespace-delimited token)
                guard let pidStr = trimmed.split(separator: " ").first,
                      let pid = Int32(pidStr) else { continue }
                kill(pid, SIGTERM)
                ClaudeBoardLog.info("archive", "Killed claude process \(pid) for session \(sessionId.prefix(8))")
            }
        } catch {
            ClaudeBoardLog.warn("archive", "Failed to find claude processes: \(error)")
        }
    }
}

/// Relay to avoid importing ClaudeBoard (UI) target from ClaudeBoardCore.
/// The actual TerminalCache is in the ClaudeBoard target and registers itself on app launch.
@MainActor
public enum TerminalCacheRelay {
    public static var removeHandler: ((String) -> Void)?

    public static func remove(_ sessionName: String) {
        removeHandler?(sessionName)
    }
}
