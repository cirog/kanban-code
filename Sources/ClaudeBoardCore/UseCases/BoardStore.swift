import Foundation

// MARK: - AppState

/// Single source of truth for the entire board.
/// All mutations go through the Reducer — no direct writes.
public struct AppState: Sendable {
    public var links: [String: Link] = [:]                     // cardId → Link
    public var sessions: [String: Session] = [:]               // sessionId → Session
    public var activityMap: [String: ActivityState] = [:]       // sessionId → activity
    public var tmuxSessions: Set<String> = []                  // live tmux names
    public var selectedCardId: String?
    public var selectedProjectPath: String?
    public var paletteOpen: Bool = false
    public var error: String?
    public var isLoading: Bool = false
    public var lastRefresh: Date?

    /// Configured projects (refreshed from settings on each reconciliation).
    public var configuredProjects: [Project] = []
    /// Cached excluded paths for global view.
    public var excludedPaths: [String] = []
    /// Project paths discovered from sessions but not yet configured.
    public var discoveredProjectPaths: [String] = []

    /// Lightweight project labels for card categorization.
    public var projectLabels: [ProjectLabel] = []

    /// Session IDs that were deliberately deleted by the user.
    /// Prevents the reconciler from recreating cards for these sessions.
    public var deletedSessionIds: Set<String> = []

    /// Card IDs that were deliberately deleted by the user.
    /// Prevents the reconciler from re-adding them during in-flight reconciliation.
    public var deletedCardIds: Set<String> = []

    /// Cards with an async operation in progress (terminal creating).
    /// Transient — not persisted. Used to show a spinner on the card.
    public var busyCards: Set<String> = []

    /// Transient map from cardId → current sessionId, rebuilt each reconciliation.
    /// Source of truth is the session_links DB table; this is just an in-memory cache.
    public var sessionIdByCardId: [String: String] = [:]

    /// Lazily-built session chains per card. Populated when History/Prompts tab opens.
    public var chainByCardId: [String: SessionChain] = [:]

    /// Reverse index: sessionId → cardId, rebuilt in rebuildCards().
    public internal(set) var cardIdBySessionId: [String: String] = [:]


    // MARK: - Derived

    /// Cached cards array — rebuilt by BoardStore after each dispatch.
    public internal(set) var cards: [ClaudeBoardCard] = []

    /// Rebuild the cached cards array and reverse session index from current state.
    mutating func rebuildCards() {
        cards = links.values.map { link in
            let sessionId = sessionIdByCardId[link.id]
            let session = sessionId.flatMap { sessions[$0] }
            let activity = sessionId.flatMap { activityMap[$0] }
            return ClaudeBoardCard(link: link, session: session, activityState: activity, isBusy: busyCards.contains(link.id))
        }
        cardIdBySessionId = Dictionary(
            sessionIdByCardId.map { ($0.value, $0.key) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    /// Cards visible after project filtering.
    public var filteredCards: [ClaudeBoardCard] {
        cards.filter { cardMatchesProjectFilter($0) }
    }

    /// Cards for a specific column, sorted by manual sortOrder then last activity (newest first).
    public func cards(in column: ClaudeBoardColumn) -> [ClaudeBoardCard] {
        filteredCards.filter { $0.column == column }
            .sorted {
                switch ($0.link.sortOrder, $1.link.sortOrder) {
                case (let a?, let b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    let t0 = $0.link.lastActivity ?? $0.link.updatedAt
                    let t1 = $1.link.lastActivity ?? $1.link.updatedAt
                    if t0 != t1 { return t0 > t1 }
                    return $0.id < $1.id
                }
            }
    }

    /// Count of cards in a column across ALL projects (no filtering).
    /// Used by the system tray badge/visibility — the menu bar icon is global.
    public func globalCardCount(in column: ClaudeBoardColumn) -> Int {
        cards.filter { $0.column == column }.count
    }

    /// The visible columns (non-empty or always-shown).
    public var visibleColumns: [ClaudeBoardColumn] {
        return [.backlog, .inProgress, .waiting]
    }

    private func cardMatchesProjectFilter(_ card: ClaudeBoardCard) -> Bool {
        guard let selectedPath = selectedProjectPath else {
            return !isExcludedFromGlobalView(card)
        }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalizedCard = ProjectDiscovery.normalizePath(cardPath)
        let normalizedSelected = ProjectDiscovery.normalizePath(selectedPath)

        // Direct match: card is at or under the selected project
        if normalizedCard == normalizedSelected || normalizedCard.hasPrefix(normalizedSelected + "/") {
            return true
        }

        return false
    }

    private func isExcludedFromGlobalView(_ card: ClaudeBoardCard) -> Bool {
        guard !excludedPaths.isEmpty else { return false }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalized = ProjectDiscovery.normalizePath(cardPath)
        for excluded in excludedPaths {
            let normalizedExcluded = ProjectDiscovery.normalizePath(excluded)
            if normalized == normalizedExcluded || normalized.hasPrefix(normalizedExcluded + "/") {
                return true
            }
        }
        return false
    }

    public init() {}
}

// MARK: - Action

/// Exhaustive enum of everything that can happen to the board.
public enum Action: Sendable {
    // UI actions
    case createManualTask(Link)
    case createTerminal(cardId: String)
    case addExtraTerminal(cardId: String, sessionName: String)
    case launchCard(cardId: String, prompt: String, projectPath: String, commandOverride: String?)
    case resumeCard(cardId: String)
    case moveCard(cardId: String, to: ClaudeBoardColumn)
    case renameCard(cardId: String, name: String)
    case archiveCard(cardId: String)
    case deleteCard(cardId: String)
    case selectCard(cardId: String?)
    case setPaletteOpen(Bool)
    case unlinkFromCard(cardId: String, linkType: LinkType)
    case killTerminal(cardId: String, sessionName: String)
    case cancelLaunch(cardId: String)
    case moveCardToProject(cardId: String, projectPath: String)
    case moveCardToFolder(cardId: String, folderPath: String, parentProjectPath: String)
    case beginMigration(cardId: String)
    case migrateSession(cardId: String, newAssistant: CodingAssistant, newSessionId: String)
    case migrationFailed(cardId: String, error: String)
    case mergeCards(sourceId: String, targetId: String)
    case updatePrompt(cardId: String, body: String, imagePaths: [String]?)
    case reorderCard(cardId: String, targetCardId: String, above: Bool)

    // Queued prompts
    case addQueuedPrompt(cardId: String, prompt: QueuedPrompt)
    case updateQueuedPrompt(cardId: String, promptId: String, body: String, sendAutomatically: Bool)
    case removeQueuedPrompt(cardId: String, promptId: String)
    case sendQueuedPrompt(cardId: String, promptId: String)

    // Async completions
    case launchCompleted(cardId: String, tmuxName: String, sessionId: String?, sessionPath: String?)
    case launchTmuxReady(cardId: String)
    case launchFailed(cardId: String, error: String)
    case resumeCompleted(cardId: String, tmuxName: String)
    case resumeFailed(cardId: String, error: String)
    case terminalCreated(cardId: String, tmuxName: String)
    case terminalFailed(cardId: String, error: String)
    case extraTerminalCreated(cardId: String, sessionName: String)
    case renameTerminalTab(cardId: String, sessionName: String, label: String)
    case reorderTerminalTab(cardId: String, sessionName: String, beforeSession: String?)

    // Session mapping (immediate, e.g. fork — reconciler will confirm on next cycle)
    case setSessionMapping(cardId: String, sessionId: String)

    // Background reconciliation
    case reconciled(ReconciliationResult)
    case activityChanged([String: ActivityState]) // sessionId → state

    // Busy state (transient spinners)
    case setBusy(cardId: String, busy: Bool)

    // Settings / misc
    case settingsLoaded(projects: [Project], excludedPaths: [String], projectLabels: [ProjectLabel])
    case setError(String?)
    case setSelectedProject(String?)
    case setLoading(Bool)

    // Project labels
    case setProject(cardId: String, projectId: String?)

    // Notes
    case updateNotes(cardId: String, notes: String?)

    // Tab memory
    case setLastTab(cardId: String, tab: String)

    // Chains
    case loadChain(cardId: String, limit: Int = 5)
    case chainLoaded(String, SessionChain) // (cardId, chain)
    case chainInvalidated(String) // cardId

    // Todoist sync
    case todoistSyncCompleted([TodoistTask])

    public enum LinkType: Sendable {
        case tmux
    }
}

/// Bundles the result of a full background reconciliation cycle.
public struct ReconciliationResult: Sendable {
    public let links: [Link]
    public let sessions: [Session]
    public let isClaudeRunning: [String: Bool]     // sessionId → PID alive?
    public let lastHookEvent: [String: String]      // sessionId → latest event name
    public let activityMap: [String: ActivityState]  // kept for .activityChanged compat
    public let tmuxSessions: Set<String>
    public let configuredProjects: [Project]
    public let excludedPaths: [String]
    public let discoveredProjectPaths: [String]
    public let associations: [CardReconciler.SessionAssociation]
    public init(
        links: [Link],
        sessions: [Session],
        isClaudeRunning: [String: Bool] = [:],
        lastHookEvent: [String: String] = [:],
        activityMap: [String: ActivityState] = [:],
        tmuxSessions: Set<String>,
        configuredProjects: [Project] = [],
        excludedPaths: [String] = [],
        discoveredProjectPaths: [String] = [],
        associations: [CardReconciler.SessionAssociation] = []
    ) {
        self.links = links
        self.sessions = sessions
        self.isClaudeRunning = isClaudeRunning
        self.lastHookEvent = lastHookEvent
        self.activityMap = activityMap
        self.tmuxSessions = tmuxSessions
        self.configuredProjects = configuredProjects
        self.excludedPaths = excludedPaths
        self.discoveredProjectPaths = discoveredProjectPaths
        self.associations = associations
    }
}

// MARK: - Effect

/// Side effects returned by the reducer. Executed asynchronously by EffectHandler.
public enum Effect: Sendable {
    case persistLinks([Link], associations: [CardReconciler.SessionAssociation])
    case upsertLink(Link)
    case removeLink(String) // id
    case createTmuxSession(cardId: String, name: String, path: String)
    case killTmuxSession(String) // name
    case killTmuxSessions([String])
    case deleteSessionFile(String) // path
    case cleanupTerminalCache(sessionNames: [String])
    case refreshDiscovery
    case updateSessionIndex(sessionId: String, name: String)
    case moveSessionFile(cardId: String, sessionId: String, oldPath: String, newProjectPath: String)
    case sendPromptToTmux(sessionName: String, promptBody: String, assistant: CodingAssistant)
    case sendPromptWithImagesToTmux(sessionName: String, promptBody: String, imagePaths: [String], assistant: CodingAssistant)
    case deleteFiles([String])
    case completeTodoistTask(todoistId: String)
    case killClaudeProcess(sessionId: String)
    case loadChain(cardId: String, limit: Int)
}

// MARK: - Reducer

/// Pure function: (state, action) → (state', effects).
/// No async. No side effects. Fully testable.
public enum Reducer {
    public static func reduce(state: inout AppState, action: Action) -> [Effect] {
        switch action {

        // MARK: UI Actions

        case .createManualTask(let link):
            state.links[link.id] = link
            return [.upsertLink(link)]

        case .createTerminal(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let projectName = link.projectPath.map { ($0 as NSString).lastPathComponent } ?? "shell"
            let tmuxName = "\(projectName)-\(link.id)"
            link.tmuxLink = TmuxLink(sessionName: tmuxName, isShellOnly: true)
            // Do NOT change column. Terminal ≠ in progress.
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.insert(cardId)
            let workDir = link.projectPath ?? NSHomeDirectory()
            return [.createTmuxSession(cardId: cardId, name: tmuxName, path: workDir), .upsertLink(link)]

        case .addExtraTerminal(let cardId, let sessionName):
            guard var link = state.links[cardId] else { return [] }
            let workDir = link.projectPath ?? NSHomeDirectory()
            // Add to extra sessions list
            var extras = link.tmuxLink?.extraSessions ?? []
            extras.append(sessionName)
            link.tmuxLink?.extraSessions = extras
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.insert(cardId)
            return [.createTmuxSession(cardId: cardId, name: sessionName, path: workDir), .upsertLink(link)]

        case .launchCard(let cardId, _, let projectPath, _):
            guard var link = state.links[cardId] else { return [] }
            let projectName = (projectPath as NSString).lastPathComponent
            let tmuxName = "\(projectName)-\(cardId)"
            // Store projectPath if not already set
            if link.projectPath == nil {
                link.projectPath = projectPath
            }
            // Preserve existing shell sessions as extras
            var extras = link.tmuxLink?.extraSessions ?? []
            if link.tmuxLink?.isShellOnly == true, let oldPrimary = link.tmuxLink?.sessionName {
                extras.insert(oldPrimary, at: 0)
            }
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: extras.isEmpty ? nil : extras)
            link.column = .inProgress
            link.manualOverrides.column = false // Let automatic assignment take over
            link.isLaunching = true
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            ClaudeBoardLog.info("store", "Launch: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .resumeCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let sid = state.sessionIdByCardId[cardId] ?? link.id
            let tmuxName = "\(link.effectiveAssistant.cliCommand)-\(String(sid.prefix(8)))"
            // Preserve existing shell sessions as extras
            var extras = link.tmuxLink?.extraSessions ?? []
            if link.tmuxLink?.isShellOnly == true, let oldPrimary = link.tmuxLink?.sessionName {
                extras.insert(oldPrimary, at: 0)
            }
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: extras.isEmpty ? nil : extras)
            link.column = .inProgress
            link.manualOverrides.column = false // Let automatic assignment take over
            link.isLaunching = true
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            ClaudeBoardLog.info("store", "Resume: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .moveCard(let cardId, let column):
            guard var link = state.links[cardId] else { return [] }
            // Clear sortOrder when moving to a different column
            link.sortOrder = nil
            link.column = column
            link.manualOverrides.column = true
            if column == .done {
                link.manuallyArchived = true
                let archiveEffects = archiveLinkEffects(link: &link, sessionId: state.sessionIdByCardId[cardId])
                state.links[cardId] = link
                return [.upsertLink(link)] + archiveEffects
            } else if link.manuallyArchived {
                link.manuallyArchived = false
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .reorderCard(let cardId, let targetCardId, let above):
            guard let link = state.links[cardId] else { return [] }
            let column = link.column
            // Get current sorted order for the column
            var columnCards = state.cards(in: column)
            // Remove the dragged card
            columnCards.removeAll { $0.id == cardId }
            // Find insertion index
            let insertIndex: Int
            if let targetIdx = columnCards.firstIndex(where: { $0.id == targetCardId }) {
                insertIndex = above ? targetIdx : targetIdx + 1
            } else {
                insertIndex = columnCards.count
            }
            // Re-insert the dragged card as a placeholder (we only need the id)
            let draggedCard = state.cards.first { $0.id == cardId }!
            columnCards.insert(draggedCard, at: insertIndex)
            // Assign sortOrder 0, 1, 2, ... to all cards in the column
            var effects: [Effect] = []
            for (i, card) in columnCards.enumerated() {
                if state.links[card.id] != nil {
                    state.links[card.id]!.sortOrder = i
                    effects.append(.upsertLink(state.links[card.id]!))
                }
            }
            return effects

        case .renameCard(let cardId, let name):
            guard var link = state.links[cardId] else { return [] }
            link.name = name
            link.manualOverrides.name = true
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if let sessionId = state.sessionIdByCardId[cardId] {
                effects.append(.updateSessionIndex(sessionId: sessionId, name: name))
            }
            return effects

        case .updatePrompt(let cardId, let body, let imagePaths):
            guard var link = state.links[cardId] else { return [] }
            let oldImages = link.promptImagePaths ?? []
            let newImages = Set(imagePaths ?? [])
            let removedImages = oldImages.filter { !newImages.contains($0) }
            link.promptBody = body
            link.promptImagePaths = imagePaths
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if !removedImages.isEmpty {
                effects.append(.deleteFiles(removedImages))
            }
            return effects

        case .archiveCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            link.manuallyArchived = true
            link.column = .done
            let archiveEffects = archiveLinkEffects(link: &link, sessionId: state.sessionIdByCardId[cardId])
            state.links[cardId] = link
            return [.upsertLink(link)] + archiveEffects

        case .deleteCard(let cardId):
            guard let link = state.links.removeValue(forKey: cardId) else { return [] }
            if state.selectedCardId == cardId { state.selectedCardId = nil }
            // Remember deleted IDs so in-flight reconciliation doesn't re-add them
            state.deletedCardIds.insert(cardId)
            if let sessionId = state.sessionIdByCardId.removeValue(forKey: cardId) {
                state.deletedSessionIds.insert(sessionId)
            }
            var effects: [Effect] = [.removeLink(cardId)]
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
            }
            // Clean up prompt and queued prompt images
            var imagesToDelete = link.promptImagePaths ?? []
            imagesToDelete += (link.queuedPrompts ?? []).flatMap { $0.imagePaths ?? [] }
            if !imagesToDelete.isEmpty {
                effects.append(.deleteFiles(imagesToDelete))
            }
            return effects

        case .selectCard(let cardId):
            state.selectedCardId = cardId
            if let cardId, var link = state.links[cardId] {
                link.lastOpenedAt = Date()
                state.links[cardId] = link
                return [.upsertLink(link)]
            }
            return []

        case .setPaletteOpen(let open):
            state.paletteOpen = open
            return []

        case .unlinkFromCard(let cardId, let linkType):
            guard var link = state.links[cardId] else { return [] }
            switch linkType {
            case .tmux:
                link.tmuxLink = nil
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .killTerminal(let cardId, let sessionName):
            guard var link = state.links[cardId] else { return [] }
            if sessionName == link.tmuxLink?.sessionName {
                // Killing primary session
                if link.tmuxLink?.extraSessions != nil {
                    // Extras exist — keep tmuxLink, mark primary dead
                    link.tmuxLink?.isPrimaryDead = true
                    link.isLaunching = nil
                    link.updatedAt = .now
                    state.links[cardId] = link
                    return [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]
                } else {
                    // No extras — full teardown
                    link.tmuxLink = nil
                    link.isLaunching = nil
                    link.updatedAt = .now
                    state.links[cardId] = link
                    return [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]
                }
            } else {
                // Killing extra session
                link.tmuxLink?.extraSessions?.removeAll { $0 == sessionName }
                if link.tmuxLink?.extraSessions?.isEmpty == true {
                    link.tmuxLink?.extraSessions = nil
                }
                // If primary is dead and no extras left, full teardown
                if link.tmuxLink?.isPrimaryDead == true && link.tmuxLink?.extraSessions == nil {
                    link.tmuxLink = nil
                }
                link.updatedAt = .now
                state.links[cardId] = link
                return [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]
            }

        case .cancelLaunch(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let tmuxName = link.tmuxLink?.sessionName
            link.isLaunching = nil
            link.tmuxLink = nil
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if let tmuxName {
                effects.append(.killTmuxSession(tmuxName))
                effects.append(.cleanupTerminalCache(sessionNames: [tmuxName]))
            }
            return effects

        case .addQueuedPrompt(let cardId, let prompt):
            guard var link = state.links[cardId] else { return [] }
            var prompts = link.queuedPrompts ?? []
            prompts.append(prompt)
            link.queuedPrompts = prompts
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .updateQueuedPrompt(let cardId, let promptId, let body, let sendAutomatically):
            guard var link = state.links[cardId] else { return [] }
            guard var prompts = link.queuedPrompts,
                  let idx = prompts.firstIndex(where: { $0.id == promptId }) else { return [] }
            prompts[idx].body = body
            prompts[idx].sendAutomatically = sendAutomatically
            link.queuedPrompts = prompts
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .removeQueuedPrompt(let cardId, let promptId):
            guard var link = state.links[cardId] else { return [] }
            link.queuedPrompts?.removeAll { $0.id == promptId }
            if link.queuedPrompts?.isEmpty == true { link.queuedPrompts = nil }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .sendQueuedPrompt(let cardId, let promptId):
            guard var link = state.links[cardId] else { return [] }
            guard let prompts = link.queuedPrompts,
                  let prompt = prompts.first(where: { $0.id == promptId }),
                  let sessionName = link.tmuxLink?.sessionName else { return [] }
            link.queuedPrompts?.removeAll { $0.id == promptId }
            if link.queuedPrompts?.isEmpty == true { link.queuedPrompts = nil }
            link.updatedAt = .now
            state.links[cardId] = link
            let sendEffect: Effect
            if let imagePaths = prompt.imagePaths, !imagePaths.isEmpty {
                sendEffect = .sendPromptWithImagesToTmux(sessionName: sessionName, promptBody: prompt.body, imagePaths: imagePaths, assistant: link.effectiveAssistant)
            } else {
                sendEffect = .sendPromptToTmux(sessionName: sessionName, promptBody: prompt.body, assistant: link.effectiveAssistant)
            }
            return [.upsertLink(link), sendEffect]

        case .moveCardToProject(let cardId, let projectPath):
            guard var link = state.links[cardId] else { return [] }
            let oldProjectPath = link.projectPath
            link.projectPath = projectPath
            // Kill tmux sessions — they're running in the old project
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            link.updatedAt = .now
            state.links[cardId] = link
            effects.insert(.upsertLink(link), at: 0)
            // Move the .jsonl file to the new project folder
            if let sessionId = state.sessionIdByCardId[cardId],
               let session = state.sessions[sessionId],
               let oldPath = session.jsonlPath,
               oldProjectPath != projectPath {
                effects.append(.moveSessionFile(
                    cardId: cardId,
                    sessionId: sessionId,
                    oldPath: oldPath,
                    newProjectPath: projectPath
                ))
            }
            ClaudeBoardLog.info("store", "MoveToProject: card=\(cardId.prefix(12)) → \(projectPath)")
            return effects

        case .moveCardToFolder(let cardId, let folderPath, let parentProjectPath):
            guard var link = state.links[cardId] else { return [] }
            let oldProjectPath = link.projectPath
            link.projectPath = parentProjectPath
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            link.updatedAt = .now
            state.links[cardId] = link
            effects.insert(.upsertLink(link), at: 0)
            // Move the session file — use folderPath for file location (not parentProjectPath)
            if let sessionId = state.sessionIdByCardId[cardId],
               let session = state.sessions[sessionId],
               let oldPath = session.jsonlPath {
                effects.append(.moveSessionFile(
                    cardId: cardId,
                    sessionId: sessionId,
                    oldPath: oldPath,
                    newProjectPath: folderPath
                ))
            }
            ClaudeBoardLog.info("store", "MoveToFolder: card=\(cardId.prefix(12)) folder=\(folderPath) project=\(parentProjectPath)")
            return effects

        case .beginMigration(let cardId):
            guard var link = state.links[cardId] else { return [] }
            link.isLaunching = true
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.insert(cardId)
            return []

        case .migrateSession(let cardId, let newAssistant, let newSessionId):
            guard var link = state.links[cardId] else { return [] }
            // Mark old session as deleted so reconciler won't recreate a card for it
            if let oldSessionId = state.sessionIdByCardId[cardId] {
                state.deletedSessionIds.insert(oldSessionId)
            }
            link.assistant = newAssistant
            state.sessionIdByCardId[cardId] = newSessionId
            // Kill tmux sessions — the old assistant process must stop
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.remove(cardId)
            ClaudeBoardLog.info("store", "MigrateSession: card=\(cardId.prefix(12)) → \(newAssistant)")
            effects.insert(.upsertLink(link), at: 0)
            return effects

        case .migrationFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.remove(cardId)
            state.error = "Migration failed: \(error)"
            return []

        case .mergeCards(let sourceId, let targetId):
            guard let source = state.links[sourceId],
                  var target = state.links[targetId],
                  sourceId != targetId else { return [] }

            // Validation: don't merge two cards that both have sessions
            let sourceHasSession = state.sessionIdByCardId[sourceId] != nil
            let targetHasSession = state.sessionIdByCardId[targetId] != nil
            if sourceHasSession && targetHasSession {
                state.error = "Cannot merge: both cards have sessions"
                return []
            }
            // Don't merge two cards that both have tmux terminals
            if source.tmuxLink != nil && target.tmuxLink != nil {
                state.error = "Cannot merge: both cards have terminals"
                return []
            }
            // Transfer links from source → target (only fill nil slots)
            if target.tmuxLink == nil { target.tmuxLink = source.tmuxLink }
            if target.projectPath == nil { target.projectPath = source.projectPath }
            if target.name == nil { target.name = source.name }
            if target.promptBody == nil { target.promptBody = source.promptBody }
            // Transfer session mapping if source had one
            if let sourceSessionId = state.sessionIdByCardId[sourceId],
               state.sessionIdByCardId[targetId] == nil {
                state.sessionIdByCardId[targetId] = sourceSessionId
            }
            // Preserve the more recent lastActivity
            if let sourceActivity = source.lastActivity {
                if target.lastActivity == nil || sourceActivity > target.lastActivity! {
                    target.lastActivity = sourceActivity
                }
            }
            target.updatedAt = .now
            state.links[targetId] = target

            // Remove source card
            state.links.removeValue(forKey: sourceId)
            state.deletedCardIds.insert(sourceId)
            if let sourceSessionId = state.sessionIdByCardId.removeValue(forKey: sourceId),
               state.sessionIdByCardId[targetId] != sourceSessionId {
                state.deletedSessionIds.insert(sourceSessionId)
            }
            if state.selectedCardId == sourceId { state.selectedCardId = targetId }

            ClaudeBoardLog.info("store", "Merge: \(sourceId.prefix(12)) → \(targetId.prefix(12))")
            return [.upsertLink(target), .removeLink(sourceId)]

        // MARK: Async Completions

        case .launchCompleted(let cardId, let tmuxName, let sessionId, _):
            guard var link = state.links[cardId] else { return [] }
            let existingExtras = link.tmuxLink?.extraSessions
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: existingExtras)
            if let sessionId { state.sessionIdByCardId[cardId] = sessionId }
            link.isLaunching = nil
            link.lastActivity = .now
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .launchTmuxReady(let cardId):
            guard var link = state.links[cardId] else { return [] }
            // Keep isLaunching=true — prevents reconciler from overriding column
            // before the first reconcile links the session. The UI can show the
            // terminal via tmuxLink even with isLaunching still set.
            link.lastActivity = .now
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .launchFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.error = "Launch failed: \(error)"
            return [.upsertLink(link)]

        case .resumeCompleted(let cardId, let tmuxName):
            guard var link = state.links[cardId] else { return [] }
            let existingExtras = link.tmuxLink?.extraSessions
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: existingExtras)
            link.isLaunching = nil
            link.lastActivity = .now
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .resumeFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.error = "Resume failed: \(error)"
            return [.upsertLink(link)]

        case .terminalCreated(let cardId, _):
            state.busyCards.remove(cardId)
            return []

        case .terminalFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.remove(cardId)
            state.error = "Terminal failed: \(error)"
            return [.upsertLink(link)]

        case .extraTerminalCreated(let cardId, _):
            state.busyCards.remove(cardId)
            return []

        case .renameTerminalTab(let cardId, let sessionName, let label):
            guard var link = state.links[cardId],
                  var tmux = link.tmuxLink else { return [] }
            var names = tmux.tabNames ?? [:]
            if label.isEmpty {
                names.removeValue(forKey: sessionName)
            } else {
                names[sessionName] = label
            }
            tmux.tabNames = names.isEmpty ? nil : names
            link.tmuxLink = tmux
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .reorderTerminalTab(let cardId, let sessionName, let beforeSession):
            guard var link = state.links[cardId],
                  var tmux = link.tmuxLink,
                  var extras = tmux.extraSessions,
                  let fromIndex = extras.firstIndex(of: sessionName) else { return [] }
            extras.remove(at: fromIndex)
            if let before = beforeSession, let toIndex = extras.firstIndex(of: before) {
                extras.insert(sessionName, at: toIndex)
            } else {
                extras.append(sessionName)
            }
            tmux.extraSessions = extras
            link.tmuxLink = tmux
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        // MARK: Session Mapping

        case .setSessionMapping(let cardId, let sessionId):
            state.sessionIdByCardId[cardId] = sessionId
            return []

        // MARK: Background Reconciliation

        case .reconciled(let result):
            state.tmuxSessions = result.tmuxSessions
            state.configuredProjects = result.configuredProjects
            state.excludedPaths = result.excludedPaths
            state.discoveredProjectPaths = result.discoveredProjectPaths

            // Merge sessions: update existing, add new, but never remove a previously
            // known session. This prevents transient file I/O gaps from causing
            // session → nil → session flicker, which triggers header height oscillation
            // and terminal SIGWINCH repaints.
            let incoming = Dictionary(
                result.sessions.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            for (id, session) in incoming {
                state.sessions[id] = session
            }
            // Merge activity: update known sessions, preserve existing entries
            // for sessions not in this cycle (same rationale as session merge).
            for (id, activity) in result.activityMap {
                state.activityMap[id] = activity
            }

            // Merge reconciled links with in-memory state.
            // In-memory wins when it has a newer updatedAt (user action during reconciliation).
            var mergedLinks = state.links
            for link in result.links {
                if state.deletedCardIds.contains(link.id) { continue }
                if let sessionId = state.sessionIdByCardId[link.id], state.deletedSessionIds.contains(sessionId) { continue }

                if let existing = mergedLinks[link.id] {
                    // In-memory is newer — preserve it, skip stale reconciled data
                    if existing.updatedAt > link.updatedAt {
                        continue
                    }

                    // Reconciled data is newer — take it, but preserve user overrides
                    var merged = link
                    if existing.manualOverrides.name {
                        merged.name = existing.name
                        merged.manualOverrides.name = true
                    }
                    if existing.manuallyArchived {
                        merged.manuallyArchived = true
                        merged.column = .done
                    }
                    if existing.manualOverrides.column {
                        merged.column = existing.column
                        merged.manualOverrides.column = true
                    }
                    mergedLinks[link.id] = merged
                } else {
                    // New card from reconciler (discovered)
                    mergedLinks[link.id] = link
                }
            }

            // Recompute columns using PID-based detection
            for (id, var link) in mergedLinks where link.isLaunching != true {
                let sessionId = state.sessionIdByCardId[id] ?? ""
                let running = result.isClaudeRunning[sessionId] ?? false
                let hookEvent = result.lastHookEvent[sessionId]

                UpdateCardColumn.update(
                    link: &link,
                    isClaudeRunning: running,
                    lastHookEvent: hookEvent
                )

                // Backfill slug and promptBody from session when missing
                // (e.g., scheduled tasks created externally without tmux)
                if let sessionId = state.sessionIdByCardId[id],
                   let session = result.sessions.first(where: { $0.id == sessionId }) {
                    if link.slug == nil, let slug = session.slug {
                        link.slug = slug
                    }
                    if link.promptBody == nil,
                       let firstPrompt = session.firstPrompt, !firstPrompt.isEmpty {
                        link.promptBody = firstPrompt
                    }
                }

                mergedLinks[id] = link
            }

            state.links = mergedLinks
            state.lastRefresh = Date()
            state.isLoading = false

            // Validate selected card still exists
            if let selectedId = state.selectedCardId,
               !mergedLinks.keys.contains(selectedId) {
                state.selectedCardId = nil
            }

            return [.persistLinks(Array(mergedLinks.values), associations: result.associations)]

        case .activityChanged(let activityMap):
            // Lightweight column update — no full reconciliation, just activity → column
            var changed = false
            for (id, var link) in state.links where link.isLaunching != true {
                // Skip discovered cards — their columns are set by PID-based reconcile only
                guard link.source != .discovered else { continue }
                guard let sessionId = state.sessionIdByCardId[id],
                      let activity = activityMap[sessionId] else { continue }
                let oldColumn = link.column
                // Convert ActivityState to PID-based signals for UpdateCardColumn
                let isRunning = activity == .activelyWorking || activity == .needsAttention || activity == .idleWaiting
                let hookEvent: String? = switch activity {
                    case .activelyWorking: "UserPromptSubmit"
                    case .needsAttention: "Stop"
                    case .idleWaiting: "SessionStart"
                    case .ended: "SessionEnd"
                    case .stale: nil
                }
                UpdateCardColumn.update(link: &link, isClaudeRunning: isRunning, lastHookEvent: hookEvent)
                if link.column != oldColumn {
                    state.links[id] = link
                    changed = true
                }
            }
            state.activityMap = activityMap
            return changed ? [.persistLinks(Array(state.links.values), associations: [])] : []

        // MARK: Busy State

        case .setBusy(let cardId, let busy):
            if busy {
                state.busyCards.insert(cardId)
            } else {
                state.busyCards.remove(cardId)
            }
            return []

        // MARK: Project Labels

        case .setProject(let cardId, let projectId):
            guard var link = state.links[cardId] else { return [] }
            link.projectId = projectId
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        // MARK: Notes

        case .updateNotes(let cardId, let notes):
            guard var link = state.links[cardId] else { return [] }
            link.notes = notes
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        // MARK: Tab Memory

        case .setLastTab(let cardId, let tab):
            guard var link = state.links[cardId] else { return [] }
            link.lastTab = tab
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        // MARK: Settings / Misc

        case .settingsLoaded(let projects, let excludedPaths, let projectLabels):
            state.configuredProjects = projects
            state.excludedPaths = excludedPaths
            state.projectLabels = projectLabels
            return []

        case .setError(let message):
            state.error = message
            return []

        case .setSelectedProject(let path):
            state.selectedProjectPath = path
            return []

        case .setLoading(let loading):
            state.isLoading = loading
            return []

        // MARK: Chains

        case .loadChain(let cardId, let limit):
            return [.loadChain(cardId: cardId, limit: limit)]

        case .chainLoaded(let cardId, let chain):
            state.chainByCardId[cardId] = chain
            return []

        case .chainInvalidated(let cardId):
            state.chainByCardId[cardId] = nil
            return []

        // MARK: Todoist Sync

        case .todoistSyncCompleted(let tasks):
            // Build lookup of existing links by todoistId
            var existingByTodoistId: [String: Link] = [:]
            for link in state.links.values {
                if let tid = link.todoistId {
                    existingByTodoistId[tid] = link
                }
            }

            let incomingIds = Set(tasks.map(\.id))

            // Upsert: update existing or create new
            for task in tasks {
                if var existing = existingByTodoistId[task.id] {
                    existing.name = task.content
                    existing.todoistDescription = task.description
                    existing.todoistPriority = task.priority
                    existing.todoistDue = task.due
                    existing.todoistLabels = task.labels
                    existing.todoistProjectId = task.projectId
                    existing.updatedAt = .now
                    state.links[existing.id] = existing
                } else {
                    let newLink = Link(
                        name: task.content,
                        column: .backlog,
                        source: .todoist,
                        todoistId: task.id,
                        todoistDescription: task.description,
                        todoistPriority: task.priority,
                        todoistDue: task.due,
                        todoistLabels: task.labels,
                        todoistProjectId: task.projectId
                    )
                    state.links[newLink.id] = newLink
                }
            }

            // Archive todoist links in backlog whose todoistId is no longer in incoming tasks
            for (tid, existing) in existingByTodoistId {
                if !incomingIds.contains(tid) && existing.column == .backlog {
                    var link = existing
                    link.column = .done
                    link.manuallyArchived = true
                    link.updatedAt = .now
                    state.links[link.id] = link
                }
            }

            return [.persistLinks(Array(state.links.values), associations: [])]
        }
    }

    /// Shared side-effects for moving a card to Done: kill tmux, complete Todoist.
    /// Mutates link in-place (clears tmuxLink, sets updatedAt).
    private static func archiveLinkEffects(link: inout Link, sessionId: String?) -> [Effect] {
        link.updatedAt = .now
        var effects: [Effect] = []
        if let tmux = link.tmuxLink {
            effects.append(.killTmuxSessions(tmux.allSessionNames))
            effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
            link.tmuxLink = nil
        }
        if let sessionId {
            effects.append(.killClaudeProcess(sessionId: sessionId))
        }
        if let todoistId = link.todoistId {
            effects.append(.completeTodoistTask(todoistId: todoistId))
        }
        return effects
    }
}

// MARK: - BoardStore

/// The main store. Replaces BoardState as the single source of truth.
/// All mutations go through dispatch() → Reducer → Effects.
@Observable
@MainActor
public final class BoardStore: @unchecked Sendable {
    public private(set) var state: AppState
    private let effectHandler: EffectHandler
    private var _lastErrorId: UUID?

    // Dependencies for reconciliation
    private var isReconciling = false
    public var appIsActive: Bool = true
    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: (any ActivityDetector)?
    private let settingsStore: SettingsStore?
    private let tmuxAdapter: TmuxManagerPort?
    private let hookEventStore: HookEventStore?

    public let sessionStore: SessionStore

    public init(
        effectHandler: EffectHandler,
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: (any ActivityDetector)? = nil,
        settingsStore: SettingsStore? = nil,
        tmuxAdapter: TmuxManagerPort? = nil,
        sessionStore: SessionStore = ClaudeCodeSessionStore(),
        hookEventStore: HookEventStore? = nil
    ) {
        self.state = AppState()
        self.effectHandler = effectHandler
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.settingsStore = settingsStore
        self.tmuxAdapter = tmuxAdapter
        self.sessionStore = sessionStore
        self.hookEventStore = hookEventStore
    }

    /// Dispatch an action. Reducer runs synchronously, effects run async.
    public func dispatch(_ action: Action) {
        let effects = Reducer.reduce(state: &state, action: action)
        state.rebuildCards()
        for effect in effects {
            Task { [weak self] in
                guard let self else { return }
                await self.effectHandler.execute(effect, dispatch: self.dispatch)
            }
        }

        // Auto-dismiss errors for certain actions
        switch action {
        case .setError(let msg) where msg != nil:
            let dismissId = UUID()
            _lastErrorId = dismissId
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?._lastErrorId == dismissId {
                    self?.state.error = nil
                }
            }
        case .launchFailed, .resumeFailed, .terminalFailed:
            let dismissId = UUID()
            _lastErrorId = dismissId
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?._lastErrorId == dismissId {
                    self?.state.error = nil
                }
            }
        default:
            break
        }
    }

    /// Dispatch an action and wait for all its effects to complete.
    public func dispatchAndWait(_ action: Action) async {
        let effects = Reducer.reduce(state: &state, action: action)
        state.rebuildCards()
        await withTaskGroup(of: Void.self) { group in
            for effect in effects {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.effectHandler.execute(effect, dispatch: self.dispatch)
                }
            }
        }
    }

    // MARK: - Activity Refresh (fast path)

    /// Lightweight activity-only refresh. Queries the activity detector for all
    /// sessions with hook data and recomputes columns immediately — no full
    /// discovery cycle. Runs in <1ms.
    public func refreshActivity() async {
        guard let activityDetector else { return }
        var activityMap: [String: ActivityState] = [:]
        for (cardId, _) in state.links {
            guard let sessionId = state.sessionIdByCardId[cardId] else { continue }
            let activity = await activityDetector.activityState(for: sessionId)
            activityMap[sessionId] = activity
        }
        if !activityMap.isEmpty {
            dispatch(.activityChanged(activityMap))
        }
    }

    // MARK: - Eager settings load

    /// Load settings and cached links immediately — populates project list
    /// and cards before the full reconcile finishes.
    public func loadSettingsAndCache() async {
        if let store = settingsStore {
            if let settings = try? await store.read() {
                dispatch(.settingsLoaded(
                    projects: settings.projects,
                    excludedPaths: settings.globalView.excludedPaths,
                    projectLabels: settings.projectLabels
                ))
            }
        }
        // Also load cached links so cards appear instantly
        if state.links.isEmpty {
            if let cached = try? await coordinationStore.readLinks(), !cached.isEmpty {
                let cleaned = AutoCleanup.clean(links: cached)
                for link in cleaned {
                    state.links[link.id] = link
                }
                state.rebuildCards()
            }
        }
    }

    // MARK: - Reconciliation

    /// Full reconciliation: discover sessions, load links, merge, assign columns.
    /// Replaces BoardState.refresh(). The async work happens here; the state mutation
    /// happens atomically via dispatch(.reconciled(...)).
    public func reconcile() async {
        // Prevent concurrent reconciliation — overlapping calls create orphan cards
        // with different IDs from the same data.
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        dispatch(.setLoading(true))
        let reconcileStart = ContinuousClock.now

        do {
            // Use in-memory settings (loaded at startup, updated via .settingsLoaded action)
            // Fall back to reading from disk if settings haven't been loaded yet
            var configuredProjects = state.configuredProjects
            var excludedPaths = state.excludedPaths
            if configuredProjects.isEmpty, let store = settingsStore {
                if let settings = try? await store.read() {
                    configuredProjects = settings.projects
                    excludedPaths = settings.globalView.excludedPaths
                    dispatch(.settingsLoaded(projects: configuredProjects, excludedPaths: excludedPaths, projectLabels: settings.projectLabels))
                }
            }

            // Show cached data immediately while discovery runs
            if state.links.isEmpty {
                let t = ContinuousClock.now
                let cached = try await coordinationStore.readLinks()
                if !cached.isEmpty {
                    let cleaned = AutoCleanup.clean(links: cached)
                    for link in cleaned {
                        state.links[link.id] = link
                    }
                }
                ClaudeBoardLog.info("reconcile", "cached links: \(t.duration(to: .now)) (\(cached.count) links)")
            }

            let t1 = ContinuousClock.now
            let allSessions = try await discovery.discoverSessions()
            let sessions = allSessions.filter { !state.deletedSessionIds.contains($0.id) }
            ClaudeBoardLog.info("reconcile", "discoverSessions: \(t1.duration(to: .now)) (\(sessions.count) sessions)")

            // Use in-memory state as source of truth — NOT disk.
            let existingLinks = Array(state.links.values)

            // Scan tmux sessions
            let t2 = ContinuousClock.now
            let tmuxSessions = (try? await tmuxAdapter?.listSessions()) ?? []
            ClaudeBoardLog.info("reconcile", "tmux: \(t2.duration(to: .now)) (\(tmuxSessions.count) sessions)")

            // Reconcile
            let t3 = ContinuousClock.now
            let existingAssociations = try await coordinationStore.allSessionAssociations()
            let allHookEvents: [HookEvent]
            if let hookEventStore {
                allHookEvents = try await hookEventStore.readAllStoredEvents()
            } else {
                allHookEvents = []
            }
            let snapshot = CardReconciler.DiscoverySnapshot(
                sessions: sessions,
                tmuxSessions: tmuxSessions,
                didScanTmux: tmuxAdapter != nil,
                hookEvents: allHookEvents,
                existingAssociations: existingAssociations
            )
            let reconcileResult = CardReconciler.reconcile(
                existing: existingLinks,
                snapshot: snapshot
            )
            let mergedLinks = reconcileResult.links
            let associations = reconcileResult.associations
            ClaudeBoardLog.info("reconcile", "reconciler: \(t3.duration(to: .now)) (\(existingLinks.count) existing → \(mergedLinks.count) reconciled, \(associations.count) associations)")

            // Build sessionIdByCardId: pick the most recently modified session per card.
            // A card can have multiple associations (session chaining). Dictionary iteration
            // order is non-deterministic, so we must compare by mtime, not insertion order.
            let sessionMtimes: [String: Date] = Dictionary(
                sessions.map { ($0.id, $0.modifiedTime) },
                uniquingKeysWith: { a, b in max(a, b) }
            )
            var sessionByCard: [String: String] = [:]
            for assoc in associations {
                let existingId = sessionByCard[assoc.cardId]
                if let existingId {
                    let existingMtime = sessionMtimes[existingId] ?? .distantPast
                    let newMtime = sessionMtimes[assoc.sessionId] ?? .distantPast
                    if newMtime > existingMtime {
                        sessionByCard[assoc.cardId] = assoc.sessionId
                    }
                } else {
                    sessionByCard[assoc.cardId] = assoc.sessionId
                }
            }
            // Invalidate cached chains for cards whose session association changed
            for (cardId, newSessionId) in sessionByCard {
                if state.sessionIdByCardId[cardId] != newSessionId {
                    state.chainByCardId[cardId] = nil
                }
            }
            // Also invalidate chains for cards that lost their session association
            for cardId in state.sessionIdByCardId.keys {
                if sessionByCard[cardId] == nil {
                    state.chainByCardId[cardId] = nil
                }
            }
            for (cardId, sessionId) in sessionByCard {
                state.sessionIdByCardId[cardId] = sessionId
            }

            // PID-based process detection
            let t4 = ContinuousClock.now
            var latestPidBySession: [String: Int] = [:]
            var latestEventBySession: [String: String] = [:]
            for event in allHookEvents {
                if let pid = event.pid {
                    latestPidBySession[event.sessionId] = pid
                }
                latestEventBySession[event.sessionId] = event.eventName
            }
            var pidAliveCache: [Int: Bool] = [:]
            for pid in Set(latestPidBySession.values) {
                pidAliveCache[pid] = ProcessChecker.isAlive(pid: pid)
            }
            var isClaudeRunningMap: [String: Bool] = [:]
            for (sessionId, pid) in latestPidBySession {
                isClaudeRunningMap[sessionId] = pidAliveCache[pid] ?? false
            }
            let aliveCount = isClaudeRunningMap.values.filter { $0 }.count
            ClaudeBoardLog.info("reconcile", "PID check: \(t4.duration(to: .now)) (\(latestPidBySession.count) sessions, \(aliveCount) alive)")

            // Build legacy activity map for .activityChanged compat
            var activityMap: [String: ActivityState] = [:]
            for (cardId, sessionId) in state.sessionIdByCardId {
                guard state.links[cardId] != nil || mergedLinks.contains(where: { $0.id == cardId }) else { continue }
                if let activity = await activityDetector?.activityState(for: sessionId) {
                    activityMap[sessionId] = activity
                }
            }

            // Compute discovered project paths
            let sessionPaths = mergedLinks.map { $0.projectPath }
            let discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
                sessionPaths: sessionPaths,
                configuredProjects: configuredProjects
            )

            // Prune old Done cards before dispatching
            let prunedLinks = AutoCleanup.clean(links: mergedLinks)

            // Dispatch reconciled result — reducer handles all state mutations atomically
            let t5 = ContinuousClock.now
            let result = ReconciliationResult(
                links: prunedLinks,
                sessions: sessions,
                isClaudeRunning: isClaudeRunningMap,
                lastHookEvent: latestEventBySession,
                activityMap: activityMap,
                tmuxSessions: Set(tmuxSessions.map(\.name)),
                configuredProjects: configuredProjects,
                excludedPaths: excludedPaths,
                discoveredProjectPaths: discoveredProjectPaths,
                associations: associations
            )
            dispatch(.reconciled(result))
            ClaudeBoardLog.info("reconcile", "dispatch: \(t5.duration(to: .now))")

            ClaudeBoardLog.info("reconcile", "TOTAL: \(reconcileStart.duration(to: .now))")
        } catch {
            ClaudeBoardLog.info("reconcile", "FAILED after \(reconcileStart.duration(to: .now)): \(error)")
            dispatch(.setError(error.localizedDescription))
            dispatch(.setLoading(false))
        }
    }

}
