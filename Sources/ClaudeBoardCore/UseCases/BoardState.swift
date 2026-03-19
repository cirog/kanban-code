import Foundation

/// A card on the Kanban board, combining Link + Session data for display.
public struct ClaudeBoardCard: Identifiable, Sendable {
    public let id: String // link.id — stable across refreshes
    public let link: Link
    public let session: Session?
    public let activityState: ActivityState?
    /// True when an async operation is in progress on this card
    /// (terminal creating, worktree cleanup, PR discovery).
    public let isBusy: Bool
    /// True when this card's repo is affected by GitHub API rate limiting.
    public let isRateLimited: Bool

    public init(link: Link, session: Session? = nil, activityState: ActivityState? = nil, isBusy: Bool = false, isRateLimited: Bool = false) {
        self.id = link.id
        self.link = link
        self.session = session
        self.activityState = activityState
        self.isBusy = isBusy
        self.isRateLimited = isRateLimited
    }

    /// Whether Claude is confirmed actively working right now (not just waiting).
    public var isActivelyWorking: Bool {
        activityState == .activelyWorking
    }

    /// Whether to show a spinner on the card.
    public var showSpinner: Bool {
        isActivelyWorking || link.isLaunching == true || isBusy
    }

    /// Best display title: link name → session display title → link fallback chain.
    public var displayTitle: String {
        if let name = link.name, !name.isEmpty { return name }
        if let session { return session.displayTitle }
        return link.displayTitle
    }

    /// Project name extracted from project path.
    public var projectName: String? {
        guard let path = link.projectPath ?? session?.projectPath else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Relative time since last activity.
    public var relativeTime: String {
        let date = link.lastActivity ?? link.updatedAt
        return Self.formatRelativeTime(date)
    }

    /// The column this card is in.
    public var column: ClaudeBoardColumn { link.column }

    static func formatRelativeTime(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days)d ago" }
        return "\(days / 30)mo ago"
    }
}

/// Observable state for the Kanban board.
/// Holds all cards grouped by column, handles refresh from discovery + coordination.
@Observable
public final class BoardState: @unchecked Sendable {
    public var cards: [ClaudeBoardCard] = []
    public var selectedCardId: String?
    public var isLoading: Bool = false
    public var lastRefresh: Date?
    public var error: String?

    /// Currently selected project path (nil = global/All Projects view).
    public var selectedProjectPath: String?

    /// Project paths discovered from sessions but not yet configured.
    public var discoveredProjectPaths: [String] = []

    /// Configured projects (refreshed from settings on each refresh).
    public var configuredProjects: [Project] = []

    /// Cached excluded paths for global view (refreshed from settings).
    private var excludedPaths: [String] = []

    /// Whether a GitHub issue refresh is currently running.
    public var isRefreshingBacklog = false

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: (any ActivityDetector)?
    private let settingsStore: SettingsStore?
    private let tmuxAdapter: TmuxAdapter?
    public let sessionStore: SessionStore

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: (any ActivityDetector)? = nil,
        settingsStore: SettingsStore? = nil,
        tmuxAdapter: TmuxAdapter? = TmuxAdapter(),
        sessionStore: SessionStore = ClaudeCodeSessionStore()
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.settingsStore = settingsStore
        self.tmuxAdapter = tmuxAdapter
        self.sessionStore = sessionStore
    }

    /// Cards visible after project filtering.
    public var filteredCards: [ClaudeBoardCard] {
        cards.filter { cardMatchesProjectFilter($0) }
    }

    /// Cards for a specific column, sorted by manual sortOrder then last activity (newest first).
    public func cards(in column: ClaudeBoardColumn) -> [ClaudeBoardCard] {
        filteredCards.filter { $0.column == column }
            .sorted {
                // Cards with sortOrder come first, ordered by sortOrder ascending
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

    /// Count of cards in a column.
    public func cardCount(in column: ClaudeBoardColumn) -> Int {
        filteredCards.filter { $0.column == column }.count
    }

    /// Check if a card matches the current project filter.
    private func cardMatchesProjectFilter(_ card: ClaudeBoardCard) -> Bool {
        guard let selectedPath = selectedProjectPath else {
            // Global view — apply exclusions
            return !isExcludedFromGlobalView(card)
        }
        // Project view — match by project path
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

    /// Check if a card should be excluded from the global view.
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

    /// The visible columns (non-empty or always-shown).
    public var visibleColumns: [ClaudeBoardColumn] {
        return [.backlog, .inProgress, .waiting]
    }

    /// Add a new card to the board immediately (synchronous, no disk round-trip).
    /// Caller should persist via coordinationStore.upsertLink() separately.
    public func addCard(link: Link) {
        let card = ClaudeBoardCard(link: link)
        cards.append(card)
    }

    /// Update a card's in-memory state for an active launch.
    /// Sets tmuxLink + column to .inProgress. Does NOT persist — caller handles persistence.
    public func updateCardForLaunch(cardId: String, tmuxName: String, isShellOnly: Bool = false) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.tmuxLink = TmuxLink(sessionName: tmuxName, isShellOnly: isShellOnly)
        link.column = .inProgress
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = ClaudeBoardCard(link: link, session: session, activityState: activity)
    }

    /// Rename a card (manual override).
    public func renameCard(cardId: String, name: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.name = name
        link.manualOverrides.name = true
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = ClaudeBoardCard(link: link, session: session, activityState: activity)

        Task {
            // Persist to our coordination store
            try? await coordinationStore.upsertLink(link)
            // Also update Claude's sessions-index.json so other tools see the rename
            if let sessionId = link.sessionLink?.sessionId {
                try? SessionIndexReader.updateSummary(sessionId: sessionId, summary: name)
            }
        }
    }

    /// Archive a card — sets manuallyArchived and moves to done.
    public func archiveCard(cardId: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.manuallyArchived = true
        link.column = .done
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = ClaudeBoardCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Delete a card permanently (manual tasks or orphan cards with no active links).
    /// Delete a card, removing it from the board and coordination store.
    /// Returns the link for cleanup (tmux kill, jsonl delete) by the caller.
    @discardableResult
    public func deleteCard(cardId: String) -> Link? {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return nil }
        let link = cards[index].link
        cards.remove(at: index)
        if selectedCardId == cardId { selectedCardId = nil }

        Task {
            try? await coordinationStore.removeLink(id: link.id)
        }
        return link
    }

    /// Reorder a card within its column by placing it above or below a target card.
    public func reorderCard(cardId: String, targetCardId: String, above: Bool) {
        guard let draggedIndex = cards.firstIndex(where: { $0.id == cardId }) else { return }
        let column = cards[draggedIndex].link.column
        var columnCards = self.cards(in: column)

        // Remove the dragged card
        columnCards.removeAll { $0.id == cardId }

        // Find insertion index
        let insertIndex: Int
        if let targetIdx = columnCards.firstIndex(where: { $0.id == targetCardId }) {
            insertIndex = above ? targetIdx : targetIdx + 1
        } else {
            insertIndex = columnCards.count
        }
        columnCards.insert(cards[draggedIndex], at: insertIndex)

        // Assign sortOrder and persist
        for (i, card) in columnCards.enumerated() {
            guard let idx = cards.firstIndex(where: { $0.id == card.id }) else { continue }
            var link = cards[idx].link
            link.sortOrder = i
            let session = cards[idx].session
            let activity = cards[idx].activityState
            cards[idx] = ClaudeBoardCard(link: link, session: session, activityState: activity)

            Task {
                try? await coordinationStore.upsertLink(link)
            }
        }
    }

    /// Move a card to a different column (manual override — e.g. user drag).
    public func moveCard(cardId: String, to column: ClaudeBoardColumn) {
        setCardColumn(cardId: cardId, to: column, manualOverride: true)
    }

    /// Set a card's column programmatically (no manual override — auto-assignment can still take over).
    public func setCardColumn(cardId: String, to column: ClaudeBoardColumn, manualOverride: Bool = false) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.column = column
        if manualOverride {
            link.manualOverrides.column = true
            // Dragging to done = archive; dragging out = unarchive
            if column == .done {
                link.manuallyArchived = true
            } else if link.manuallyArchived {
                link.manuallyArchived = false
            }
        }
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = ClaudeBoardCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Remove a typed link from a card.
    public enum LinkType: Sendable {
        case tmux
    }

    public func unlinkFromCard(cardId: String, linkType: LinkType) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        switch linkType {
        case .tmux:
            link.tmuxLink = nil
            link.manualOverrides.tmuxSession = true
        }
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = ClaudeBoardCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Set an error message that auto-dismisses after a delay.
    public func setError(_ message: String, autoDismissSeconds: Double = 8) {
        error = message
        let dismissId = UUID()
        _lastErrorId = dismissId
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoDismissSeconds))
            if _lastErrorId == dismissId {
                error = nil
            }
        }
    }
    private var _lastErrorId: UUID?

    /// Full refresh: discover sessions, load links, merge, assign columns.
    public func refresh() async {
        isLoading = true

        do {
            // Load settings for project filtering
            if let store = settingsStore {
                let settings = try await store.read()
                configuredProjects = settings.projects
                excludedPaths = settings.globalView.excludedPaths
            }

            // Show cached data immediately while discovery runs
            if cards.isEmpty {
                let cached = try await coordinationStore.readLinks()
                if !cached.isEmpty {
                    cards = cached.map { ClaudeBoardCard(link: $0) }
                }
            }

            let sessions = try await discovery.discoverSessions()
            let existingLinks = try await coordinationStore.readLinks()
            let sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Scan tmux sessions (to detect dead links)
            let tmuxSessions = (try? await tmuxAdapter?.listSessions()) ?? []

            // Reconcile: match sessions to existing cards
            let snapshot = CardReconciler.DiscoverySnapshot(
                sessions: sessions,
                tmuxSessions: tmuxSessions,
                didScanTmux: tmuxAdapter != nil
            )
            let reconcileResult = CardReconciler.reconcile(existing: existingLinks, snapshot: snapshot)
            var mergedLinks = reconcileResult.links
            ClaudeBoardLog.info("refresh", "Reconciled: \(existingLinks.count) existing → \(mergedLinks.count) reconciled (\(sessions.count) sessions)")

            // Recalculate columns: f(state) = column
            var newCards: [ClaudeBoardCard] = []
            for i in mergedLinks.indices {
                let sessionId = mergedLinks[i].sessionLink?.sessionId ?? mergedLinks[i].id
                let activity = await activityDetector?.activityState(for: sessionId)
                let oldColumn = mergedLinks[i].column
                UpdateCardColumn.update(link: &mergedLinks[i], activityState: activity)
                if mergedLinks[i].column != oldColumn {
                    let sessionIdStr = mergedLinks[i].sessionLink.map { String($0.sessionId.prefix(8)) } ?? "nil"
                    ClaudeBoardLog.info("refresh", "Column changed for \(mergedLinks[i].id.prefix(12)): \(oldColumn) → \(mergedLinks[i].column) (activity=\(activity.map { "\($0)" } ?? "nil"), source=\(mergedLinks[i].source), tmux=\(mergedLinks[i].tmuxLink?.sessionName ?? "nil"), session=\(sessionIdStr))")
                }
                // Copy session's firstPrompt into link.promptBody so notifications can use it
                if mergedLinks[i].promptBody == nil,
                   let session = mergedLinks[i].sessionLink.flatMap({ sessionsById[$0.sessionId] }),
                   let firstPrompt = session.firstPrompt, !firstPrompt.isEmpty {
                    mergedLinks[i].promptBody = firstPrompt
                }

                newCards.append(ClaudeBoardCard(
                    link: mergedLinks[i],
                    session: mergedLinks[i].sessionLink.flatMap { sessionsById[$0.sessionId] },
                    activityState: activity
                ))
            }

            cards = newCards
            lastRefresh = Date()

            // Compute discovered project paths
            let sessionPaths = newCards.map { $0.link.projectPath ?? $0.session?.projectPath }
            discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
                sessionPaths: sessionPaths,
                configuredProjects: configuredProjects
            )

            // Persist recalculated columns + merged links (atomic merge to avoid overwriting concurrent additions)
            let mergedById = Dictionary(mergedLinks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            try? await coordinationStore.modifyLinks { freshLinks in
                // Update existing links with reconciled data
                for i in freshLinks.indices {
                    if let merged = mergedById[freshLinks[i].id] {
                        freshLinks[i] = merged
                    }
                }
                // Add newly discovered links that don't exist in the store yet
                let freshIds = Set(freshLinks.map(\.id))
                for link in mergedLinks where !freshIds.contains(link.id) {
                    freshLinks.append(link)
                }
            }

            // Validate selected card still exists
            if let selectedId = selectedCardId,
               !newCards.contains(where: { $0.id == selectedId }) {
                selectedCardId = nil
            }
        } catch {
            setError(error.localizedDescription)
        }

        isLoading = false
    }

    // GitHub issue methods removed (GitHub integration stripped)
}
