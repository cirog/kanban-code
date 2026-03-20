import Foundation

extension Notification.Name {
    /// Posted when hook events are processed that should trigger a UI refresh.
    public static let claudeBoardHookEvent = Notification.Name("claudeBoardHookEvent")
}

/// Coordinates all background processes: session discovery, tmux polling,
/// hook event processing, activity detection, PR tracking, and link management.
@Observable
public final class BackgroundOrchestrator: @unchecked Sendable {
    public var isRunning = false

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: any ActivityDetector
    private let hookEventStore: HookEventStore
    private let tmux: TmuxManagerPort?
    private let notificationDedup: NotificationDeduplicator
    private var notifier: NotifierPort?
    private let registry: CodingAssistantRegistry?
    private let todoistSync: TodoistSyncService?

    private var backgroundTask: Task<Void, Never>?
    private var didInitialLoad = false
    private var dispatch: (@MainActor @Sendable (Action) -> Void)?

    /// Prompt IDs currently being edited in the UI — skip auto-send for these.
    private var editingQueuedPromptIds: Set<String> = []

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: any ActivityDetector,
        hookEventStore: HookEventStore = .init(),
        tmux: TmuxManagerPort? = nil,
        notificationDedup: NotificationDeduplicator = .init(),
        notifier: NotifierPort? = nil,
        registry: CodingAssistantRegistry? = nil,
        todoistSync: TodoistSyncService? = nil
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.hookEventStore = hookEventStore
        self.tmux = tmux
        self.notificationDedup = notificationDedup
        self.notifier = notifier
        self.registry = registry
        self.todoistSync = todoistSync
    }

    /// Start the slow background loop (columns, PRs, activity polling).
    /// Notifications are handled event-driven via processHookEvents().
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.backgroundTick()
                try? await Task.sleep(for: .seconds(5))
            }
        }

        if let todoistSync {
            Task { await todoistSync.start() }
        }
    }

    /// Update the notifier (e.g. when settings change).
    public func updateNotifier(_ newNotifier: NotifierPort?) {
        self.notifier = newNotifier
    }

    /// Mark a queued prompt as being edited — auto-send will skip it.
    public func markPromptEditing(_ promptId: String) {
        editingQueuedPromptIds.insert(promptId)
    }

    /// Clear the editing mark so auto-send can proceed.
    public func clearPromptEditing(_ promptId: String) {
        editingQueuedPromptIds.remove(promptId)
    }

    /// Set the dispatch callback for sending actions to the BoardStore.
    public func setDispatch(_ dispatch: @MainActor @Sendable @escaping (Action) -> Void) {
        self.dispatch = dispatch
        if let todoistSync {
            Task { await todoistSync.setDispatch(dispatch) }
        }
    }

    /// Stop the background loop.
    public func stop() {
        backgroundTask?.cancel()
        backgroundTask = nil
        isRunning = false
        Task { await todoistSync?.stop() }
    }

    // MARK: - Event-driven notification path (called from file watcher)

    /// Process new hook events and send notifications. Called directly by file watcher
    /// for instant response — mirrors claude-pushover's hook-driven approach.
    public func processHookEvents() async {
        do {
            let events = try await hookEventStore.readNewEvents()

            if !didInitialLoad {
                // First call: consume all old events without notifying.
                ClaudeBoardLog.info("notify", "Initial load: consuming \(events.count) old events")
                for event in events {
                    await activityDetector.handleHookEvent(event)
                }
                let _ = await activityDetector.resolvePendingStops()
                await notificationDedup.clearAllPending()
                didInitialLoad = true
                return
            }

            if !events.isEmpty {
                ClaudeBoardLog.info("notify", "Processing \(events.count) hook events")
            }

            for event in events {
                await activityDetector.handleHookEvent(event)

                // Notification logic — mirrors claude-pushover, adapted for batch processing.
                // Uses EVENT TIMESTAMPS (not wall-clock) so batch-processed events
                // behave identically to claude-pushover's one-event-per-process model.
                let eventName = HookManager.normalizeEventName(event.eventName)
                switch eventName {
                case "SessionStart":
                    // Eagerly resolve the new session to its card via tmux.
                    // This chains the session BEFORE the next reconciliation cycle,
                    // preventing duplicate card creation.
                    if let tmuxName = event.tmuxSessionName, !tmuxName.isEmpty {
                        ClaudeBoardLog.info("notify", "SessionStart for \(event.sessionId.prefix(8)) in tmux \(tmuxName)")
                        let _ = try? await Self.resolveLink(
                            sessionId: event.sessionId,
                            transcriptPath: event.transcriptPath,
                            tmuxSessionName: tmuxName,
                            coordinationStore: coordinationStore
                        )
                    }

                case "Stop":
                    // claude-pushover: sleep 0.5s, check if user prompted, send if not.
                    // NO 62s dedup — Stop always sends (dedup only applies to Notification events).
                    ClaudeBoardLog.info("notify", "Stop event for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    let stopTime = event.timestamp
                    let sessionId = event.sessionId
                    let transcriptPath = event.transcriptPath
                    let tmuxName = event.tmuxSessionName
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let self else {
                            ClaudeBoardLog.info("notify", "Stop handler: self deallocated")
                            return
                        }
                        // Check if user sent a prompt within 0.5s after this Stop
                        let prompted = await notificationDedup.hasPromptedWithin(
                            sessionId: sessionId, after: stopTime
                        )
                        if prompted {
                            ClaudeBoardLog.info("notify", "Stop skipped: user prompted within 0.5s after stop")
                            return
                        }
                        // Send directly — no dedup for Stop events (matches claude-pushover)
                        await self.doNotify(sessionId: sessionId, transcriptPath: transcriptPath, tmuxSessionName: tmuxName)

                        // Auto-send queued prompt: wait 0.5 more seconds (1s total from Stop),
                        // re-check that user hasn't prompted, then send first auto prompt.
                        try? await Task.sleep(for: .milliseconds(500))
                        let promptedAgain = await notificationDedup.hasPromptedWithin(
                            sessionId: sessionId, after: stopTime
                        )
                        if promptedAgain {
                            ClaudeBoardLog.info("notify", "Auto-send skipped: user prompted after stop")
                            return
                        }
                        await self.autoSendQueuedPrompt(sessionId: sessionId, transcriptPath: transcriptPath, tmuxSessionName: tmuxName)
                    }

                case "Notification":
                    // claude-pushover: send if not within 62s dedup window
                    ClaudeBoardLog.info("notify", "Notification event for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    let sessionId = event.sessionId
                    let eventTime = event.timestamp
                    let notifTranscriptPath = event.transcriptPath
                    let notifTmuxName = event.tmuxSessionName
                    Task { [weak self] in
                        // Notification events go through 62s dedup
                        let shouldNotify = await self?.notificationDedup.shouldNotify(
                            sessionId: sessionId, eventTime: eventTime
                        ) ?? false
                        guard shouldNotify else {
                            ClaudeBoardLog.info("notify", "Notification deduped for \(sessionId.prefix(8))")
                            return
                        }
                        await self?.doNotify(sessionId: sessionId, transcriptPath: notifTranscriptPath, tmuxSessionName: notifTmuxName)
                    }

                case "UserPromptSubmit":
                    ClaudeBoardLog.info("notify", "UserPromptSubmit for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    await notificationDedup.recordPrompt(sessionId: event.sessionId, at: event.timestamp)

                default:
                    break
                }
            }
        } catch {
            ClaudeBoardLog.info("notify", "processHookEvents error: \(error)")
        }
    }

    // MARK: - Private

    /// Send notification — no dedup check, just format and send.
    /// Mirrors claude-pushover's do_notify() exactly.
    private func doNotify(sessionId: String, transcriptPath: String? = nil, tmuxSessionName: String? = nil) async {
        guard let notifier else {
            ClaudeBoardLog.info("notify", "Notification skipped: notifier is nil")
            return
        }

        let link = try? await Self.resolveLink(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            tmuxSessionName: tmuxSessionName,
            coordinationStore: coordinationStore
        )
        let title = link?.displayTitle ?? "Session done"

        // Mirrors claude-pushover's do_notify() exactly:
        // 1. Get last assistant response
        // 2. If multi-line + render enabled: render image, message = "Task completed"
        // 3. If multi-line + no image: truncate to 1000 chars
        // 4. If single line: use as-is
        // 5. No response: "Waiting for input"
        var message = "Waiting for input"
        var imageData: Data?

        let renderMarkdown = (try? await SettingsStore().read())?.notifications.renderMarkdownImage ?? false

        if let transcriptPath = link?.sessionLink?.sessionPath {
            // Use the correct session store for the assistant
            let assistant = link?.assistant ?? .claude
            let lastText: String?
            if let store = registry?.store(for: assistant),
               let turns = try? await store.readTranscript(sessionPath: transcriptPath) {
                lastText = TranscriptNotificationReader.lastAssistantText(from: turns)
            } else {
                lastText = await TranscriptNotificationReader.lastAssistantText(transcriptPath: transcriptPath)
            }

            if let lastText {
                let lineCount = lastText.components(separatedBy: "\n").count
                if lineCount > 1 {
                    if renderMarkdown {
                        imageData = await MarkdownImageRenderer.renderToImage(markdown: lastText)
                    }
                    if imageData != nil {
                        message = "Task completed"
                    } else {
                        message = String(lastText.prefix(1000)) + (lastText.count > 1000 ? "..." : "")
                    }
                } else {
                    message = lastText
                }
            }
        }

        ClaudeBoardLog.info("notify", "Sending notification: title=\(title), message=\(message.prefix(60))..., hasImage=\(imageData != nil)")
        try? await notifier.sendNotification(
            title: title,
            message: message,
            imageData: imageData,
            cardId: link?.id
        )
    }

    /// Auto-send the first queued prompt with sendAutomatically=true for a session.
    private func autoSendQueuedPrompt(sessionId: String, transcriptPath: String? = nil, tmuxSessionName: String? = nil) async {
        do {
            guard let link = try await Self.resolveLink(
                sessionId: sessionId,
                transcriptPath: transcriptPath,
                tmuxSessionName: tmuxSessionName,
                coordinationStore: coordinationStore
            ) else {
                return
            }
            guard let prompts = link.queuedPrompts,
                  let prompt = prompts.first(where: { $0.sendAutomatically && !editingQueuedPromptIds.contains($0.id) }) else {
                return
            }
            guard link.tmuxLink?.sessionName != nil else {
                ClaudeBoardLog.info("notify", "Auto-send skipped: no tmux session for \(sessionId.prefix(8))")
                return
            }

            ClaudeBoardLog.info("notify", "Auto-sending queued prompt to \(sessionId.prefix(8)): \(prompt.body.prefix(40))...")

            // Dispatch through BoardStore — this removes from in-memory state,
            // persists to disk, and sends to tmux via effects, all in sync.
            if let dispatch {
                await dispatch(.sendQueuedPrompt(cardId: link.id, promptId: prompt.id))
            }

            // Record that we "prompted" so the next stop can trigger the next queued prompt
            await notificationDedup.recordPrompt(sessionId: sessionId, at: .now)
        } catch {
            ClaudeBoardLog.warn("notify", "autoSendQueuedPrompt failed: \(error)")
        }
    }

    /// Slow background tick: poll activity states for sessions without hook events.
    /// Column updates and PR tracking are now handled by BoardStore.reconcile().
    private func backgroundTick() async {
        await updateActivityStates()
    }

    // MARK: - Session resolution

    /// Resolve a session ID to a Link. Fast path: exact DB match.
    /// Fallback 1: read slug from .jsonl transcript, find card by slug.
    /// Fallback 2: tmux session name → card (most reliable for context resets).
    static func resolveLink(
        sessionId: String,
        transcriptPath: String?,
        tmuxSessionName: String? = nil,
        coordinationStore: CoordinationStore
    ) async throws -> Link? {
        // Fast path: session already registered
        if let link = try await coordinationStore.linkForSession(sessionId) {
            return link
        }

        // Fallback 1: read slug from transcript, find card by slug
        if let path = transcriptPath,
           let metadata = try await JsonlParser.extractMetadata(from: path),
           let slug = metadata.slug,
           let link = try await coordinationStore.findBySlug(slug) {
            ClaudeBoardLog.info("reconciler", "Hook resolution: session \(sessionId.prefix(8)) → card \(link.id.prefix(12)) via slug \(slug)")
            try await coordinationStore.addSessionPath(linkId: link.id, sessionId: sessionId, path: path)
            return try await coordinationStore.linkById(link.id)
        }

        // Fallback 2: tmux session name → card (most reliable for context resets)
        if let tmuxName = tmuxSessionName, !tmuxName.isEmpty,
           let link = try await coordinationStore.findByTmuxSessionName(tmuxName) {
            ClaudeBoardLog.info("reconciler", "Hook resolution: session \(sessionId.prefix(8)) → card \(link.id.prefix(12)) via tmux \(tmuxName)")
            try await coordinationStore.addSessionPath(linkId: link.id, sessionId: sessionId, path: transcriptPath)
            return try await coordinationStore.linkById(link.id)
        }

        return nil
    }

    private func updateActivityStates() async {
        do {
            let links = try await coordinationStore.readLinks()
            let sessionPaths = Dictionary(
                links.compactMap { link -> (String, String)? in
                    guard let sessionId = link.sessionLink?.sessionId,
                          let path = link.sessionLink?.sessionPath else { return nil }
                    return (sessionId, path)
                },
                uniquingKeysWith: { a, _ in a }
            )

            // Poll activity for sessions without hook events
            let _ = await activityDetector.pollActivity(sessionPaths: sessionPaths)
        } catch {
            // Continue on error
        }
    }
}
