import SwiftUI
import AppKit
import KanbanCodeCore

/// Bundles all parameters for the launch confirmation dialog.
/// Used with `.sheet(item:)` to guarantee all values are captured atomically.
struct LaunchConfig: Identifiable {
    let id = UUID()
    let cardId: String
    let projectPath: String
    let prompt: String
    let isResume: Bool
    let sessionId: String?
    let promptImagePaths: [String]
    let assistant: CodingAssistant

    init(
        cardId: String,
        projectPath: String,
        prompt: String,
        isResume: Bool = false,
        sessionId: String? = nil,
        promptImagePaths: [String] = [],
        assistant: CodingAssistant = .claude
    ) {
        self.cardId = cardId
        self.projectPath = projectPath
        self.prompt = prompt
        self.isResume = isResume
        self.sessionId = sessionId
        self.promptImagePaths = promptImagePaths
        self.assistant = assistant
    }
}

struct ContentView: View {
    @State private var store: BoardStore
    @State private var orchestrator: BackgroundOrchestrator
    @State private var searchInitialQuery = ""
    @State private var terminalHadFocusBeforeSearch = false
    @State private var deepSearchTrigger = false
    @State private var usageService = UsageService()
    @State private var usageData: UsageData = .empty
    @AppStorage("showBoardInExpanded") private var showBoardInExpanded = false
    @State private var showNewTask = false
    @State private var showOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @AppStorage("boardViewMode") private var boardViewModeRaw = BoardViewMode.kanban.rawValue
    @State private var showProcessManager = false
    @State private var showQuitConfirmation = false
    @State private var quitOwnedSessions: [TmuxSession] = []
    @AppStorage("killTmuxOnQuit") private var killTmuxOnQuit = true
    @AppStorage("uiTextSize") private var uiTextSize: Int = 1
    @AppStorage("detailExpanded") private var detailExpandedPersisted = false
    @State private var showAddFromPath = false
    @State private var isDroppingFolder = false
    @State private var isDroppingImage = false
    @State private var addFromPathText = ""
    @State private var launchConfig: LaunchConfig?
    @State private var syncStatuses: [String: SyncStatus] = [:]
    @State private var isSyncRefreshing = false
    @State private var showSyncPopover = false
    @State private var rawSyncOutput = ""
    @State private var editingQueuedPromptId: String?
    // showSearch and isExpandedDetail live in AppState (store.state.paletteOpen / detailExpanded)
    private var showSearch: Bool {
        get { store.state.paletteOpen }
        nonmutating set { store.dispatch(.setPaletteOpen(newValue)) }
    }
    private var isExpandedDetail: Bool {
        get { store.state.detailExpanded }
        nonmutating set { store.dispatch(.setDetailExpanded(newValue)) }
    }
    @State private var detailTab: DetailTab = .terminal
    @State private var actionsMenuProvider = ActionsMenuProvider()
    @AppStorage("preferredEditorBundleId") private var editorBundleId: String = "dev.zed.Zed"
    @AppStorage("selectedProject") private var selectedProjectPersisted: String = ""
    @AppStorage("defaultAssistant") private var defaultAssistantRaw: String = CodingAssistant.claude.rawValue
    private var defaultAssistant: CodingAssistant {
        CodingAssistant(rawValue: defaultAssistantRaw) ?? .claude
    }
    private let settingsStore: SettingsStore
    private let assistantRegistry: CodingAssistantRegistry
    private let launcher: LaunchSession
    private let tmuxAdapter: TmuxAdapter
    private let systemTray = SystemTray()
    private let mutagenAdapter = MutagenAdapter()
    private let hookEventsPath: String
    private let settingsFilePath: String

    private var boardViewMode: BoardViewMode {
        BoardViewMode(rawValue: boardViewModeRaw) ?? .kanban
    }

    private var boardViewModeBinding: Binding<BoardViewMode> {
        Binding(
            get: { boardViewMode },
            set: { boardViewModeRaw = $0.rawValue }
        )
    }

    private var viewModePicker: some View {
        Picker("View", selection: viewModePickerBinding) {
            ForEach(BoardViewMode.allCases, id: \.self) { mode in
                Image(systemName: mode.icon)
                    .tag(Optional(mode))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Binding that returns nil (nothing highlighted) when expanded with board hidden.
    private var viewModePickerBinding: Binding<BoardViewMode?> {
        Binding(
            get: {
                if isExpandedDetail && !showBoardInExpanded && store.state.selectedCardId != nil {
                    return nil // no segment highlighted
                }
                return boardViewMode
            },
            set: { newMode in
                guard let newMode else { return }
                if isExpandedDetail {
                    if showBoardInExpanded && newMode == boardViewMode {
                        showBoardInExpanded = false
                    } else {
                        boardViewModeRaw = newMode.rawValue
                        showBoardInExpanded = true
                    }
                } else {
                    boardViewModeRaw = newMode.rawValue
                }
            }
        )
    }

    init() {
        let claudeDiscovery = ClaudeCodeSessionDiscovery()
        let claudeDetector = ClaudeCodeActivityDetector()
        let claudeStore = ClaudeCodeSessionStore()

        let enabledAssistants = Self.loadEnabledAssistants()
        let registry = CodingAssistantRegistry()
        if enabledAssistants.contains(.claude) {
            registry.register(.claude, discovery: claudeDiscovery, detector: claudeDetector, store: claudeStore)
        }

        let discovery = CompositeSessionDiscovery(registry: registry)
        let activityDetector = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)

        let coordination = CoordinationStore()
        let settings = SettingsStore()
        let tmux = TmuxAdapter()

        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux
        )

        let boardStore = BoardStore(
            effectHandler: effectHandler,
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            settingsStore: settings,
            tmuxAdapter: tmux
        )

        // Load Pushover from settings.json, wrap in CompositeNotifier with macOS fallback
        let pushover = Self.loadPushoverConfig()
        let notifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient())

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: tmux,
            notifier: notifier,
            registry: registry
        )

        let launch = LaunchSession(tmux: tmux)

        orch.setDispatch { [weak boardStore] action in
            boardStore?.dispatch(action)
        }

        _store = State(initialValue: boardStore)
        _orchestrator = State(initialValue: orch)
        self.settingsStore = settings
        self.assistantRegistry = registry
        self.launcher = launch
        self.tmuxAdapter = tmux
        self.hookEventsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/hook-events.jsonl")
        self.settingsFilePath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")
    }

    private static func loadEnabledAssistants() -> [CodingAssistant] {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return CodingAssistant.allCases
        }
        return settings.enabledAssistants
    }

    private static func loadPushoverConfig() -> PushoverClient? {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return nil
        }

        guard settings.notifications.pushoverEnabled,
              let token = settings.notifications.pushoverToken,
              let user = settings.notifications.pushoverUserKey,
              !token.isEmpty, !user.isEmpty else {
            return nil
        }
        return PushoverClient(token: token, userKey: user)
    }

    private func updateRegisteredAssistants(_ enabled: [CodingAssistant]) {
        for assistant in CodingAssistant.allCases {
            if enabled.contains(assistant) {
                // Re-register if not already registered
                if assistantRegistry.discovery(for: assistant) == nil {
                    switch assistant {
                    case .claude:
                        assistantRegistry.register(.claude, discovery: ClaudeCodeSessionDiscovery(), detector: ClaudeCodeActivityDetector(), store: ClaudeCodeSessionStore())
                    }
                }
            } else {
                assistantRegistry.unregister(assistant)
            }
        }
    }

    private var boardView: some View {
        BoardView(
            store: store,
            onStartCard: { cardId in startCard(cardId: cardId) },
            onResumeCard: { cardId in resumeCard(cardId: cardId) },
            onForkCard: { cardId in pendingForkCardId = cardId },
            onCopyResumeCmd: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
                var cmd = ""
                if let projectPath = card.link.projectPath {
                    cmd += "cd \(projectPath) && "
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    cmd += "claude --resume \(sessionId)"
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            },
            onCleanupWorktree: { _ in },
            canCleanupWorktree: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return false }
                return false
            },
            onArchiveCard: { cardId in archiveCard(cardId: cardId) },
            onDeleteCard: { cardId in pendingDeleteCardId = cardId },
            availableProjects: projectList,
            onMoveToProject: { cardId, projectPath in
                let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                pendingMoveToProject = (cardId: cardId, projectPath: projectPath, projectName: name)
            },
            onMoveToFolder: { cardId in selectFolderForMove(cardId: cardId) },
            enabledAssistants: assistantRegistry.available,
            onMigrateAssistant: { cardId, target in
                pendingMigration = (cardId: cardId, targetAssistant: target)
            },
            onRefreshBacklog: { },
            canDropCard: { card, column in
                CardDropIntent.resolve(card, to: column).isAllowed
            },
            onDropCard: { cardId, column in handleDrop(cardId: cardId, to: column) },
            onMergeCards: { sourceId, targetId in
                store.dispatch(.mergeCards(sourceId: sourceId, targetId: targetId))
            },
            onNewTask: { presentNewTask() },
            onCardClicked: { cardId in
                if store.state.cards.first(where: { $0.id == cardId })?.link.tmuxLink != nil {
                    shouldFocusTerminal = true
                }
            },
            onColumnBackgroundClick: { column in
                handleColumnBackgroundClick(column)
            },
            terminalContent: AnyView(terminalPanelContent)
        )
    }

    private var listBoardView: some View {
        ListBoardView(
            store: store,
            onStartCard: { cardId in startCard(cardId: cardId) },
            onResumeCard: { cardId in resumeCard(cardId: cardId) },
            onForkCard: { cardId in pendingForkCardId = cardId },
            onCopyResumeCmd: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
                var cmd = ""
                if let projectPath = card.link.projectPath {
                    cmd += "cd \(projectPath) && "
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    cmd += "claude --resume \(sessionId)"
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            },
            onCleanupWorktree: { _ in },
            canCleanupWorktree: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return false }
                return false
            },
            onArchiveCard: { cardId in archiveCard(cardId: cardId) },
            onDeleteCard: { cardId in pendingDeleteCardId = cardId },
            availableProjects: projectList,
            onMoveToProject: { cardId, projectPath in
                let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                pendingMoveToProject = (cardId: cardId, projectPath: projectPath, projectName: name)
            },
            onMoveToFolder: { cardId in selectFolderForMove(cardId: cardId) },
            enabledAssistants: assistantRegistry.available,
            onMigrateAssistant: { cardId, target in
                pendingMigration = (cardId: cardId, targetAssistant: target)
            },
            onRefreshBacklog: { },
            onDropCard: { cardId, column in handleDrop(cardId: cardId, to: column) },
            canDropCard: { card, column in
                CardDropIntent.resolve(card, to: column).isAllowed
            },
            onNewTask: { showNewTask = true },
            onCardClicked: { cardId in
                if store.state.cards.first(where: { $0.id == cardId })?.link.tmuxLink != nil {
                    shouldFocusTerminal = true
                }
            }
        )
    }

    /// Build project path → color map from configured projects.
    private var projectColorMap: [String: String] {
        Dictionary(
            store.state.configuredProjects.map { ($0.path, $0.color) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @ViewBuilder
    private var activeBoardView: some View {
        switch boardViewMode {
        case .kanban:
            boardView
        case .list:
            listBoardView
        }
    }

    @ViewBuilder
    private var terminalPanelContent: some View {
        if let card = store.state.cards.first(where: { $0.id == store.state.selectedCardId }) {
            CardDetailView(
                card: card,
                sessionStore: assistantRegistry.store(for: card.link.effectiveAssistant) ?? store.sessionStore,
                selectedTab: $detailTab,
                onResume: {
                    if card.link.sessionLink != nil {
                        resumeCard(cardId: card.id)
                    } else {
                        startCard(cardId: card.id)
                    }
                },
                onRename: { name in
                    store.dispatch(.renameCard(cardId: card.id, name: name))
                },
                onFork: { _ in forkCard(cardId: card.id) },
                onDismiss: { store.dispatch(.selectCard(cardId: nil)) },
                onUnlink: { linkType in
                    store.dispatch(.unlinkFromCard(cardId: card.id, linkType: linkType))
                },
                onAddBranch: { branch in
                    store.dispatch(.addBranchToCard(cardId: card.id, branch: branch))
                },
                onCleanupWorktree: {
                    // worktree cleanup removed
                },
                canCleanupWorktree: false,
                onDeleteCard: {
                    pendingDeleteCardId = card.id
                },
                onCreateTerminal: {
                    createExtraTerminal(cardId: card.id)
                },
                onKillTerminal: { sessionName in
                    store.dispatch(.killTerminal(cardId: card.id, sessionName: sessionName))
                },
                onRenameTerminal: { sessionName, label in
                    store.dispatch(.renameTerminalTab(cardId: card.id, sessionName: sessionName, label: label))
                },
                onReorderTerminal: { sessionName, beforeSession in
                    store.dispatch(.reorderTerminalTab(cardId: card.id, sessionName: sessionName, beforeSession: beforeSession))
                },
                onCancelLaunch: {
                    store.dispatch(.cancelLaunch(cardId: card.id))
                },
                onAddQueuedPrompt: { prompt in
                    store.dispatch(.addQueuedPrompt(cardId: card.id, prompt: prompt))
                },
                onUpdateQueuedPrompt: { promptId, body, sendAuto in
                    store.dispatch(.updateQueuedPrompt(cardId: card.id, promptId: promptId, body: body, sendAutomatically: sendAuto))
                },
                onRemoveQueuedPrompt: { promptId in
                    store.dispatch(.removeQueuedPrompt(cardId: card.id, promptId: promptId))
                },
                onSendQueuedPrompt: { promptId in
                    store.dispatch(.sendQueuedPrompt(cardId: card.id, promptId: promptId))
                },
                onEditingQueuedPrompt: { promptId in
                    // Clear previous editing mark if any
                    if let prev = editingQueuedPromptId {
                        orchestrator.clearPromptEditing(prev)
                    }
                    editingQueuedPromptId = promptId
                    if let promptId {
                        orchestrator.markPromptEditing(promptId)
                    }
                },
                onUpdatePrompt: { body, imagePaths in
                    store.dispatch(.updatePrompt(cardId: card.id, body: body, imagePaths: imagePaths))
                },
                availableProjects: projectList,
                onMoveToProject: { projectPath in
                    let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                    pendingMoveToProject = (cardId: card.id, projectPath: projectPath, projectName: name)
                },
                onMoveToFolder: { selectFolderForMove(cardId: card.id) },
                enabledAssistants: assistantRegistry.available,
                onMigrateAssistant: { target in
                    pendingMigration = (cardId: card.id, targetAssistant: target)
                },
                actionsMenuProvider: actionsMenuProvider,
                focusTerminal: $shouldFocusTerminal,
                isExpanded: Binding(
                    get: { isExpandedDetail },
                    set: { isExpandedDetail = $0 }
                ),
                isDroppingImage: $isDroppingImage
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Select a card to view terminal")
                    .font(.app(.title3))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var boardWithOverlays: some View {
        activeBoardView
            .environment(\.projectColorMap, projectColorMap)
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle("")
            .onChange(of: store.state.selectedCardId) {
                if let cardId = store.state.selectedCardId,
                   let card = store.state.cards.first(where: { $0.id == cardId }) {
                    detailTab = DetailTab.initialTab(for: card)
                }
            }
            .onChange(of: store.state.detailExpanded) {
                if !store.state.detailExpanded {
                    showBoardInExpanded = false
                }
                detailExpandedPersisted = store.state.detailExpanded
            }
            .overlay {
                FolderDropZone(isTargeted: $isDroppingFolder) { url in
                    addDroppedFolder(url)
                }
                .allowsHitTesting(isDroppingFolder)
            }
            .overlay {
                if isDroppingFolder {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.app(size: 40))
                                    .foregroundStyle(Color.accentColor)
                                Text("Drop to add project")
                                    .font(.app(.title3, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(20)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDroppingFolder)
            .overlay {
                if let card = store.state.cards.first(where: { $0.id == store.state.selectedCardId }),
                   let sessionName = card.link.tmuxLink?.sessionName {
                    ImageDropZone(isTargeted: $isDroppingImage) { imageData in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setData(imageData, forType: .png)
                        Task { try? await self.tmuxAdapter.sendBracketedPaste(to: sessionName) }
                    }
                    .allowsHitTesting(isDroppingImage)
                } else {
                    // No terminal open — don't show image drop zone
                    Color.clear
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDroppingImage)
    }

    private var boardWithSheets: some View {
        boardWithOverlays
            .sheet(isPresented: $showNewTask) {
                NewTaskDialog(
                    isPresented: $showNewTask,
                    projects: store.state.configuredProjects,
                    defaultProjectPath: store.state.selectedProjectPath,
                    onCreate: { prompt, projectPath, title, startImmediately, images in
                        createManualTask(prompt: prompt, projectPath: projectPath, title: title, startImmediately: startImmediately, images: images)
                    }
                )
            }
            .sheet(isPresented: $showAddFromPath) {
                addFromPathSheet
            }
            .sheet(item: $launchConfig) { config in
                LaunchConfirmationDialog(
                    cardId: config.cardId,
                    projectPath: config.projectPath,
                    initialPrompt: config.prompt,
                    isResume: config.isResume,
                    sessionId: config.sessionId,
                    promptImagePaths: config.promptImagePaths,
                    assistant: config.assistant,
                    isPresented: Binding(
                        get: { launchConfig != nil },
                        set: { if !$0 { launchConfig = nil } }
                    )
                ) { editedPrompt, _, _, runRemotely, skipPermissions, commandOverride, images in
                    if config.isResume {
                        executeResume(cardId: config.cardId, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride, assistant: config.assistant)
                    } else {
                        executeLaunch(cardId: config.cardId, prompt: editedPrompt, projectPath: config.projectPath, worktreeName: nil, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride, images: images, assistant: config.assistant)
                    }
                }
            }
            .sheet(isPresented: $showProcessManager) {
                ProcessManagerView(
                    store: store,
                    isPresented: $showProcessManager,
                    onSelectCard: { cardId in
                        store.dispatch(.selectCard(cardId: cardId))
                    }
                )
            }
    }

    private var boardWithAlerts: some View {
        boardWithSheets
            .alert(
                "Delete Card",
                isPresented: Binding(
                    get: { pendingDeleteCardId != nil },
                    set: { if !$0 { pendingDeleteCardId = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingDeleteCardId = nil
                }
                Button("Delete", role: .destructive) {
                    if let cardId = pendingDeleteCardId {
                        let nextId = cardIdAfterDeletion(cardId)
                        store.dispatch(.deleteCard(cardId: cardId))
                        if let nextId {
                            store.dispatch(.selectCard(cardId: nextId))
                        }
                    }
                    pendingDeleteCardId = nil
                }
            } message: {
                Text("This will permanently delete this card and its data.")
            }
            .alert(
                "Archive Card?",
                isPresented: Binding(
                    get: { pendingArchiveCardId != nil },
                    set: { if !$0 { pendingArchiveCardId = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingArchiveCardId = nil
                }
                Button("Archive & Kill Terminals", role: .destructive) {
                    if let cardId = pendingArchiveCardId {
                        store.dispatch(.archiveCard(cardId: cardId))
                    }
                    pendingArchiveCardId = nil
                }
            } message: {
                Text("This card has running terminals. Archiving will kill them.")
            }
            .alert(
                "Fork Session?",
                isPresented: Binding(
                    get: { pendingForkCardId != nil },
                    set: { if !$0 { pendingForkCardId = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingForkCardId = nil
                }
                Button("Fork") {
                    if let cardId = pendingForkCardId { forkCard(cardId: cardId) }
                    pendingForkCardId = nil
                }
            } message: {
                Text("This creates a duplicate session you can resume independently.")
            }
            .alert(
                "Move to Project?",
                isPresented: Binding(
                    get: { pendingMoveToProject != nil },
                    set: { if !$0 { pendingMoveToProject = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingMoveToProject = nil
                }
                Button("Move") {
                    if let pending = pendingMoveToProject {
                        store.dispatch(.moveCardToProject(cardId: pending.cardId, projectPath: pending.projectPath))
                    }
                    pendingMoveToProject = nil
                }
            } message: {
                if let pending = pendingMoveToProject {
                    Text("Move this card to \(pending.projectName)?")
                }
            }
            .alert(
                "Move to Folder?",
                isPresented: Binding(
                    get: { pendingMoveToFolder != nil },
                    set: { if !$0 { pendingMoveToFolder = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingMoveToFolder = nil
                }
                Button("Move") {
                    if let pending = pendingMoveToFolder {
                        store.dispatch(.moveCardToFolder(
                            cardId: pending.cardId,
                            folderPath: pending.folderPath,
                            parentProjectPath: pending.parentProjectPath
                        ))
                    }
                    pendingMoveToFolder = nil
                }
            } message: {
                if let pending = pendingMoveToFolder {
                    let relative = pending.folderPath.hasPrefix(pending.parentProjectPath + "/")
                        ? String(pending.folderPath.dropFirst(pending.parentProjectPath.count + 1))
                        : pending.folderPath
                    if pending.folderPath != pending.parentProjectPath {
                        Text("Move session to \(relative) (under \(pending.displayName))?")
                    } else {
                        Text("Move session to \(pending.displayName)?")
                    }
                }
            }
            .alert(
                "Migrate Session?",
                isPresented: Binding(
                    get: { pendingMigration != nil },
                    set: { if !$0 { pendingMigration = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingMigration = nil
                }
                Button("Migrate") {
                    if let pending = pendingMigration {
                        Task { await executeMigration(cardId: pending.cardId, targetAssistant: pending.targetAssistant) }
                    }
                    pendingMigration = nil
                }
            } message: {
                if let pending = pendingMigration {
                    let card = store.state.cards.first(where: { $0.id == pending.cardId })
                    let source = card?.link.effectiveAssistant.displayName ?? "current assistant"
                    Text("Migrate this session from \(source) to \(pending.targetAssistant.displayName)? A backup of the original session will be kept.")
                }
            }
    }

    private var boardWithHandlers: some View {
        boardWithAlerts
            .task {
                applyAppearance()
                // Restore persisted project selection
                if !selectedProjectPersisted.isEmpty {
                    let settings = try? await settingsStore.read()
                    let validPaths = Set(settings?.projects.map(\.path) ?? [])
                    if validPaths.contains(selectedProjectPersisted) {
                        store.dispatch(.setSelectedProject(selectedProjectPersisted))
                    } else {
                        selectedProjectPersisted = ""
                    }
                }
                // Restore persisted detail expansion
                if detailExpandedPersisted {
                    store.dispatch(.setDetailExpanded(true))
                }
                // Register TerminalCache relay for KanbanCodeCore effects
                TerminalCacheRelay.removeHandler = { name in
                    TerminalCache.shared.remove(name)
                }
                systemTray.setup(store: store)
                await store.loadSettingsAndCache()
                await store.reconcile()
                systemTray.update()
                orchestrator.start()
            }
            .task(id: "hook-watcher") {
                await watchHookEvents(path: hookEventsPath)
            }
            .task(id: "settings-watcher") {
                await watchSettingsFile(path: settingsFilePath)
            }
            .task(id: "refresh-timer") {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { break }
                    await store.reconcile()
                    systemTray.update()
                }
            }
            .task(id: "usage-poll") {
                await usageService.start()
                while !Task.isCancelled {
                    usageData = await usageService.currentUsage()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onAppear { installKeyMonitor() }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeNewTask)) { _ in
                presentNewTask()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeHookEvent)) { _ in
                Task {
                    await orchestrator.processHookEvents()
                    await store.refreshActivity()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSelectCard)) { notification in
                if let cardId = notification.userInfo?["cardId"] as? String {
                    store.dispatch(.selectCard(cardId: cardId))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSettingsChanged)) { _ in
                Task {
                    await store.loadSettingsAndCache()
                    await store.reconcile()
                    applyAppearance()
                    // Refresh notifier so Pushover credentials changes take effect immediately
                    let pushover = Self.loadPushoverConfig()
                    let newNotifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient())
                    orchestrator.updateNotifier(newNotifier)
                    // Update registry for enabled/disabled assistants
                    if let settings = try? await settingsStore.read() {
                        updateRegisteredAssistants(settings.enabledAssistants)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeQuitRequested)) { _ in
                let sessions = store.state.cards.compactMap { card -> TmuxSession? in
                    guard let tmux = card.link.tmuxLink else { return nil }
                    return TmuxSession(name: tmux.sessionName, path: card.link.projectPath ?? "")
                }
                if sessions.isEmpty {
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else {
                    quitOwnedSessions = sessions
                    showQuitConfirmation = true
                    Task.detached {
                        let live = AppDelegate.listAllTmuxSessionsSync()
                        let liveNames = Set(live.map(\.name))
                        let updated = sessions.map { s in
                            TmuxSession(name: s.name, path: s.path, attached: liveNames.contains(s.name))
                        }
                        await MainActor.run { quitOwnedSessions = updated }
                    }
                }
            }
            .sheet(isPresented: $showQuitConfirmation) {
                quitConfirmationSheet
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.appIsActive = true
                Task {
                    await store.reconcile()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                store.appIsActive = false
            }
    }

    var body: some View {
        NavigationStack {
        boardWithHandlers
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { presentNewTask() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New task (⌘N)")

                    Button { Task { await store.reconcile() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.state.isLoading)
                    .help("Refresh sessions")

                    Button {
                        appearanceMode = appearanceMode.next
                        applyAppearance()
                    } label: {
                        Image(systemName: appearanceMode.icon)
                    }
                    .help(appearanceMode.helpText)
                }

                ToolbarItem(placement: .navigation) {
                    projectSelectorMenu
                }

                ToolbarItem(placement: .navigation) {
                    viewModePicker
                }

                ToolbarItem(placement: .navigation) {
                    if currentProjectHasRemote {
                        syncStatusView
                    }
                }

                if isExpandedDetail, let card = store.state.cards.first(where: { $0.id == store.state.selectedCardId }) {
                    ToolbarItemGroup(placement: .navigation) {
                        HStack {
                            Text("⠀⠀" + card.displayTitle)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 200)

                            if card.link.cardLabel == .session {
                                Text(card.relativeTime)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }

                            Picker("", selection: $detailTab) {
                                Text("Terminal").tag(DetailTab.terminal)
                                Text("History").tag(DetailTab.history)
                                if card.link.promptBody != nil { Text("Prompt").tag(DetailTab.prompt) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button { isExpandedDetail = false } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                        }
                        .help("Contract (⌘⏎)")
                    }

                    ToolbarItem(placement: .primaryAction) {
                        if let path = card.link.projectPath {
                            Button {
                                EditorDiscovery.open(path: path, bundleId: editorBundleId)
                            } label: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                            }
                            .help("Open in editor")
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        expandedActionsMenu
                    }
                }

                ToolbarItemGroup(placement: .principal) {
                    UsageBarView(label: "5h", utilization: usageData.fiveHourUtilization, resetsAt: usageData.fiveHourResetsAt)
                    UsageBarView(label: "7d", utilization: usageData.sevenDayUtilization, resetsAt: usageData.sevenDayResetsAt)
                }

            }
            .background { shortcutButtons }
        } // NavigationStack
        .id(uiTextSize) // Force full re-render when UI scale changes
    }

    /// Watch ~/.kanban-code/hook-events.jsonl for writes → post notification.
    private nonisolated func watchHookEvents(path: String) async {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let fd = open(path, O_EVTONLY) as Int32?,
              fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated)
        )

        let events = AsyncStream<Void> { continuation in
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }

        KanbanCodeLog.info("watcher", "File watcher started for hook-events.jsonl")
        for await _ in events {
            KanbanCodeLog.info("watcher", "hook-events.jsonl changed")
            NotificationCenter.default.post(name: .kanbanCodeHookEvent, object: nil)
        }
        KanbanCodeLog.info("watcher", "File watcher loop exited (cancelled?)")

        close(fd)
    }

    /// Watch ~/.kanban-code/settings.json for changes → hot-reload.
    /// Only needed for external edits (e.g. manual file editing).
    /// In-app settings changes post `.kanbanCodeSettingsChanged` directly.
    private nonisolated func watchSettingsFile(path: String) async {
        guard FileManager.default.fileExists(atPath: path) else { return }

        guard let fd = open(path, O_EVTONLY) as Int32?,
              fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        let events = AsyncStream<Void> { continuation in
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }

        for await _ in events {
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }

        close(fd)
    }

    // MARK: - Project Selector Menu

    private var projectSelectorMenu: some View {
        Menu {
            Button {
                setSelectedProject(nil)
            } label: {
                HStack {
                    Text("All Projects")
                    Spacer()
                    Text("\(store.state.cards.count)")
                        .foregroundStyle(.secondary)
                        .font(.app(.caption))
                    if store.state.selectedProjectPath == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            let visibleProjects = store.state.configuredProjects.filter(\.visible)
            if !visibleProjects.isEmpty {
                Divider()
                ForEach(visibleProjects) { project in
                    Button {
                        setSelectedProject(project.path)
                    } label: {
                        HStack {
                            Text(project.name)
                            Spacer()
                            let count = store.state.cards.filter { $0.link.projectPath == project.path }.count
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                                    .font(.app(.caption))
                            }
                            if store.state.selectedProjectPath == project.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            let discovered = store.state.discoveredProjectPaths
            if !discovered.isEmpty {
                Divider()
                Section("Discovered") {
                    ForEach(discovered.prefix(8), id: \.self) { path in
                        Button {
                            addDiscoveredProject(path: path)
                        } label: {
                            Label(
                                (path as NSString).lastPathComponent,
                                systemImage: "folder.badge.plus"
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Add from folder...") {
                addProjectViaFolderPicker()
            }

            Button("Add from path...") {
                addFromPathText = ""
                showAddFromPath = true
            }

            Button("Process Manager...") {
                showProcessManager = true
            }

            SettingsLink {
                Text("Settings...")
            }
        } label: {
            Text(currentProjectName)
                .font(.app(.headline))
        }
    }

    // MARK: - Keyboard Shortcuts

    private var shortcutContext: AppShortcutContext {
        AppShortcutContext(from: store.state, terminalTabActive: detailTab == .terminal)
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        // Always render all shortcut buttons — SwiftUI doesn't reliably
        // register/deregister .keyboardShortcut when views appear/disappear.
        // Instead, check isActive inside the action closure.

        // Palette open/close
        Button("") { if showSearch { closePalette() } else { openPalette() } }
            .keyboardShortcut(AppShortcut.openPaletteK.key, modifiers: AppShortcut.openPaletteK.modifiers)
            .hidden()
        Button("") { if showSearch { closePalette() } else { openPalette() } }
            .keyboardShortcut(AppShortcut.openPaletteP.key, modifiers: AppShortcut.openPaletteP.modifiers)
            .hidden()
        Button("") { if showSearch { closePalette() } else { openPalette(initialQuery: ">") } }
            .keyboardShortcut(AppShortcut.openCommandMode.key, modifiers: AppShortcut.openCommandMode.modifiers)
            .hidden()

        // Cmd+Enter — expand detail OR deep search depending on context
        Button("") {
            let ctx = shortcutContext
            if AppShortcut.deepSearch.isActive(in: ctx) {
                deepSearchTrigger.toggle()
            } else if AppShortcut.toggleExpanded.isActive(in: ctx) {
                isExpandedDetail.toggle()
            }
        }
        .keyboardShortcut(AppShortcut.toggleExpanded.key, modifiers: AppShortcut.toggleExpanded.modifiers)
        .hidden()

        // Cmd+T — new terminal tab (only when detail open on terminal tab)
        Button("") {
            if AppShortcut.newTerminal.isActive(in: shortcutContext),
               let cardId = store.state.selectedCardId {
                createExtraTerminal(cardId: cardId)
            }
        }
        .keyboardShortcut(AppShortcut.newTerminal.key, modifiers: AppShortcut.newTerminal.modifiers)
        .hidden()

        // Board navigation — guarded by context
        Button("") { if AppShortcut.deselect.isActive(in: shortcutContext) { store.dispatch(.selectCard(cardId: nil)) } }
            .keyboardShortcut(AppShortcut.deselect.key, modifiers: AppShortcut.deselect.modifiers)
            .hidden()
        Button("") { if AppShortcut.deleteCard.isActive(in: shortcutContext) { deleteSelectedCard() } }
            .keyboardShortcut(AppShortcut.deleteCard.key, modifiers: AppShortcut.deleteCard.modifiers)
            .hidden()
        Button("") { if AppShortcut.deleteCardForward.isActive(in: shortcutContext) { deleteSelectedCard() } }
            .keyboardShortcut(AppShortcut.deleteCardForward.key, modifiers: AppShortcut.deleteCardForward.modifiers)
            .hidden()

        // Cmd+1-9: terminal tab switching (when detail open) or project switching
        ForEach(Array(AppShortcut.allCases.filter { $0.projectIndex != nil }), id: \.projectIndex) { shortcut in
            Button("") {
                let ctx = shortcutContext
                if ctx.detailOpen && !ctx.paletteOpen {
                    selectTerminalTab(at: shortcut.projectIndex!)
                } else {
                    selectProject(at: shortcut.projectIndex!)
                }
            }
            .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            .hidden()
        }
    }

    // paletteCommands removed (search overlay stripped)

    private var currentProjectName: String {
        guard let path = store.state.selectedProjectPath else { return "All Projects" }
        return store.state.configuredProjects.first(where: { $0.path == path })?.name
            ?? (path as NSString).lastPathComponent
    }

    private var projectList: [(name: String, path: String)] {
        var seen = Set<String>()
        var result: [(name: String, path: String)] = []
        // Only configured projects — discovered paths are auto-assigned,
        // "Move to Project" is for intentionally moving between configured projects.
        for project in store.state.configuredProjects {
            guard seen.insert(project.path).inserted else { continue }
            result.append((name: project.name, path: project.path))
        }
        return result
    }

    private var currentProjectHasRemote: Bool {
        false
    }

    private var currentSyncStatus: SyncStatus {
        if syncStatuses.isEmpty { return .notRunning }
        if syncStatuses.values.contains(.error) { return .error }
        if syncStatuses.values.contains(.conflicts) { return .conflicts }
        if syncStatuses.values.contains(.paused) { return .paused }
        if syncStatuses.values.contains(.staging) { return .staging }
        if syncStatuses.values.contains(.watching) { return .watching }
        return .notRunning
    }

    // MARK: - Quit Confirmation

    private var quitConfirmationSheet: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.app(.largeTitle))
                    .foregroundStyle(.secondary)
                Text("Quit Kanban?")
                    .font(.app(.headline))
                Text("You have \(quitOwnedSessions.count) managed tmux session\(quitOwnedSessions.count == 1 ? "" : "s") running.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            Table(quitOwnedSessions) {
                TableColumn("") { session in
                    Circle()
                        .fill(session.attached ? .green : .gray)
                        .frame(width: 8, height: 8)
                }
                .width(16)

                TableColumn("Session") { session in
                    Text(session.name)
                        .lineLimit(1)
                }

                TableColumn("Card") { session in
                    if let card = store.state.cards.first(where: { card in
                        card.link.tmuxLink?.allSessionNames.contains(session.name) == true
                    }) {
                        Text(card.displayTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TableColumn("Path") { session in
                    Text(abbreviateHomePath(session.path))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Toggle("Kill managed sessions on quit", isOn: $killTmuxOnQuit)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") {
                    showQuitConfirmation = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
                .keyboardShortcut(.cancelAction)
                Button("Quit Kanban") {
                    showQuitConfirmation = false
                    if killTmuxOnQuit {
                        Task {
                            // Kill tmux sessions and remove terminal associations from cards
                            let killedNames = Set(quitOwnedSessions.map(\.name))
                            for card in store.state.cards {
                                if let tmux = card.link.tmuxLink, killedNames.contains(tmux.sessionName) {
                                    await store.dispatchAndWait(.killTerminal(cardId: card.id, sessionName: tmux.sessionName))
                                }
                            }
                            NSApp.reply(toApplicationShouldTerminate: true)
                        }
                    } else {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    @ViewBuilder
    private var syncStatusView: some View {
        Button { showSyncPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: syncStatusIcon(currentSyncStatus))
                    .foregroundStyle(currentSyncStatus == .watching ? .primary : syncStatusColor(currentSyncStatus))
                Text(syncStatusLabel(currentSyncStatus))
                    .font(.app(.headline))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .help("Mutagen file sync status")
        .task(id: currentSyncStatus) {
            await refreshSyncStatus()
            let interval: Duration = currentSyncStatus == .staging ? .seconds(1) : .seconds(10)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await refreshSyncStatus()
            }
        }
        .popover(isPresented: $showSyncPopover) {
            syncStatusPopover
        }
        .onChange(of: currentSyncStatus) {
            if showSyncPopover {
                showSyncPopover = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showSyncPopover = true
                }
            }
        }
    }

    @ViewBuilder
    private var syncStatusPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File sync for remote Claude Code sessions, configured in Settings > Remote.")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: syncStatusIcon(currentSyncStatus))
                    .foregroundStyle(syncStatusColor(currentSyncStatus))
                Text(syncStatusLabel(currentSyncStatus))
                    .font(.app(.callout))
            }

            ScrollView {
                Text(rawSyncOutput)
                    .font(.app(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .id(rawSyncOutput.count)
            .frame(maxHeight: 250)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 4) {
                Text("mutagen sync list -l")
                    .font(.app(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("mutagen sync list -l", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.app(.caption))
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }

            HStack {
                Button {
                    Task {
                        isSyncRefreshing = true
                        try? await mutagenAdapter.flushSync()
                        await refreshSyncStatus()
                    }
                } label: {
                    Label("Flush", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncRefreshing)

                if currentSyncStatus == .notRunning {
                    Button {
                        Task {
                            isSyncRefreshing = true
                            // Remote sync removed
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncRefreshing)
                }

                if currentSyncStatus == .error || currentSyncStatus == .paused {
                    Button {
                        Task {
                            isSyncRefreshing = true
                            for name in syncStatuses.keys {
                                try? await mutagenAdapter.resetSync(name: name)
                            }
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Restart", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncRefreshing)
                }

                if !syncStatuses.isEmpty {
                    Button {
                        Task {
                            isSyncRefreshing = true
                            for name in syncStatuses.keys {
                                try? await mutagenAdapter.stopSync(name: name)
                            }
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncRefreshing)
                }

                Spacer()

                Button {
                    Task { await refreshSyncStatus() }
                } label: {
                    if isSyncRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncRefreshing)
                .help("Refresh status")
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func refreshSyncStatus() async {
        guard await mutagenAdapter.isAvailable() else {
            syncStatuses = [:]
            rawSyncOutput = "Mutagen is not installed."
            return
        }
        isSyncRefreshing = true
        defer { isSyncRefreshing = false }
        syncStatuses = (try? await mutagenAdapter.status()) ?? [:]
        rawSyncOutput = (try? await mutagenAdapter.rawStatus()) ?? "Failed to fetch status."
    }

    private func syncStatusIcon(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "checkmark.circle.fill"
        case .staging: "arrow.triangle.2.circlepath"
        case .conflicts: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .notRunning: "circle.dashed"
        }
    }

    private func syncStatusColor(_ status: SyncStatus) -> Color {
        switch status {
        case .watching: .green
        case .staging: .secondary
        case .conflicts: .yellow
        case .paused: .yellow
        case .error: .red
        case .notRunning: .secondary
        }
    }

    private func syncStatusLabel(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "Files in Sync"
        case .staging: "Syncing Files…"
        case .conflicts: "Conflicts Detected"
        case .paused: "Sync Paused"
        case .error: "Sync Error"
        case .notRunning: "Sync Not Running"
        }
    }

    /// Find the card that should be selected after deleting the given card.
    /// Prefers the card directly below; if last in column, selects the one above.
    private func cardIdAfterDeletion(_ cardId: String) -> String? {
        for col in store.state.visibleColumns {
            let colCards = store.state.cards(in: col)
            if let idx = colCards.firstIndex(where: { $0.id == cardId }) {
                if idx + 1 < colCards.count {
                    return colCards[idx + 1].id
                } else if idx > 0 {
                    return colCards[idx - 1].id
                }
                return nil
            }
        }
        return nil
    }

    private func deleteSelectedCard() {
        if let cardId = store.state.selectedCardId {
            pendingDeleteCardId = cardId
        }
    }

    // MARK: - Expanded Actions Menu

    /// Builds a SwiftUI Menu from CardDetailView's NSMenu builder, reusing icons and items.
    private var expandedActionsMenu: some View {
        Menu {
            if let menu = actionsMenuProvider.builder?() {
                ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
                    if item.isSeparatorItem {
                        Divider()
                    } else if let submenu = item.submenu {
                        Menu(item.title) {
                            ForEach(Array(submenu.items.enumerated()), id: \.offset) { _, sub in
                                Button {
                                    (sub.representedObject as? NSMenuActionItem)?.invoke()
                                } label: {
                                    if let img = sub.image {
                                        Label { Text(sub.title) } icon: { Image(nsImage: img) }
                                    } else {
                                        Text(sub.title)
                                    }
                                }
                            }
                        }
                    } else {
                        Button {
                            (item.representedObject as? NSMenuActionItem)?.invoke()
                        } label: {
                            if let img = item.image {
                                Label { Text(item.title) } icon: { Image(nsImage: img) }
                            } else {
                                Text(item.title)
                            }
                        }
                        .disabled(!item.isEnabled)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .help("More actions")
    }

    // MARK: - Keyboard Navigation

    /// Installs an NSEvent local monitor for arrow keys + Enter.
    /// Skips handling when a terminal view (LocalProcessTerminalView) is the first responder,
    /// so typing in the Claude Code terminal works normally.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't intercept if a terminal, text field, text view, or table has focus
            if let responder = event.window?.firstResponder {
                let responderType = String(describing: type(of: responder))
                if responderType.contains("Terminal")
                    || responder is NSTextView
                    || responder is NSTextField
                    || responder is NSTableView {
                    return event
                }
            }

            switch event.specialKey {
            case .upArrow:
                navigateCard(.up); return nil
            case .downArrow:
                navigateCard(.down); return nil
            case .leftArrow:
                navigateCard(.left); return nil
            case .rightArrow:
                navigateCard(.right); return nil
            case .carriageReturn, .newline, .enter:
                // Confirm pending delete alert via Enter
                if let cardId = pendingDeleteCardId {
                    let nextId = cardIdAfterDeletion(cardId)
                    store.dispatch(.deleteCard(cardId: cardId))
                    if let nextId {
                        store.dispatch(.selectCard(cardId: nextId))
                    }
                    pendingDeleteCardId = nil
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private enum NavDirection { case up, down, left, right, open }

    private func navigateCard(_ direction: NavDirection) {
        let columns = store.state.visibleColumns
        guard !columns.isEmpty else { return }

        // If opening and a card is selected, just ensure inspector is visible (it already is via binding)
        if direction == .open {
            if store.state.selectedCardId == nil {
                // Select first card in first non-empty column
                for col in columns {
                    let colCards = store.state.cards(in: col)
                    if let first = colCards.first {
                        store.dispatch(.selectCard(cardId: first.id))
                        return
                    }
                }
            }
            return
        }

        // Find current card's column and index
        guard let selectedId = store.state.selectedCardId else {
            // Nothing selected — select first card in first non-empty column
            for col in columns {
                let colCards = store.state.cards(in: col)
                if let first = colCards.first {
                    store.dispatch(.selectCard(cardId: first.id))
                    return
                }
            }
            return
        }

        // Find which column and index the selected card is in
        var currentCol: KanbanCodeColumn?
        var currentIndex = 0
        for col in columns {
            let colCards = store.state.cards(in: col)
            if let idx = colCards.firstIndex(where: { $0.id == selectedId }) {
                currentCol = col
                currentIndex = idx
                break
            }
        }

        guard let col = currentCol else { return }
        let colCards = store.state.cards(in: col)

        switch direction {
        case .down:
            let nextIndex = min(currentIndex + 1, colCards.count - 1)
            store.dispatch(.selectCard(cardId: colCards[nextIndex].id))
        case .up:
            let prevIndex = max(currentIndex - 1, 0)
            store.dispatch(.selectCard(cardId: colCards[prevIndex].id))
        case .left, .right:
            guard let colIdx = columns.firstIndex(of: col) else { return }
            let step = direction == .left ? -1 : 1
            var targetColIdx = colIdx + step
            // Skip empty columns
            while targetColIdx >= 0, targetColIdx < columns.count {
                let targetCards = store.state.cards(in: columns[targetColIdx])
                if !targetCards.isEmpty {
                    let targetIndex = min(currentIndex, targetCards.count - 1)
                    store.dispatch(.selectCard(cardId: targetCards[targetIndex].id))
                    return
                }
                targetColIdx += step
            }
        case .open:
            break // handled above
        }
    }

    private var isTerminalFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return String(describing: type(of: responder)).contains("Terminal")
    }

    private func openPalette(initialQuery: String = "") {
        // Check terminal focus via first responder first, fall back to tab+tmux heuristic
        // (by the time this runs, the shortcut may have stolen first responder from terminal)
        let terminalWasFocused = isTerminalFocused || (
            detailTab == .terminal
            && store.state.selectedCardId.flatMap({ store.state.links[$0]?.tmuxLink }) != nil
        )
        terminalHadFocusBeforeSearch = terminalWasFocused
        searchInitialQuery = initialQuery
        showSearch = true
    }

    private func closePalette() {
        showSearch = false
        if terminalHadFocusBeforeSearch {
            // Delay past the dismiss animation (150ms) so the terminal can accept focus.
            // Use direct AppKit focus as the SwiftUI binding path can miss updates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                refocusTerminal()
            }
        }
    }

    private func refocusTerminal() {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }
        func findTerminal(in view: NSView) -> NSView? {
            let typeName = String(describing: type(of: view))
            if typeName.contains("TerminalView"), view.acceptsFirstResponder, !view.isHidden {
                return view
            }
            for sub in view.subviews where !sub.isHidden {
                if let found = findTerminal(in: sub) { return found }
            }
            return nil
        }
        if let terminal = findTerminal(in: contentView) {
            window.makeFirstResponder(terminal)
        }
    }

    private func setSelectedProject(_ path: String?) {
        store.dispatch(.setSelectedProject(path))
        selectedProjectPersisted = path ?? ""
    }

    private func selectProject(at index: Int) {
        if index == 0 {
            setSelectedProject(nil)
            return
        }
        let visibleProjects = store.state.configuredProjects.filter(\.visible)
        let projectIndex = index - 1
        guard projectIndex < visibleProjects.count else { return }
        setSelectedProject(visibleProjects[projectIndex].path)
    }

    private func selectTerminalTab(at index: Int) {
        NotificationCenter.default.post(
            name: .kanbanSelectTerminalTab,
            object: nil,
            userInfo: ["index": index]
        )
    }

    private func addDroppedFolder(_ url: URL) {
        let path = url.path
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await store.reconcile()
            setSelectedProject(path)
        }
    }

    private func addProjectViaFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await store.reconcile()
            setSelectedProject(path)
        }
    }

    private func addDiscoveredProject(path: String) {
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await store.reconcile()
            setSelectedProject(path)
        }
    }

    // MARK: - Add from Path Sheet

    private var addFromPathSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project")
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField("Project path (e.g. ~/Projects/my-repo)", text: $addFromPathText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddFromPath = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    let path = (addFromPathText as NSString).expandingTildeInPath
                    let project = Project(path: path)
                    Task {
                        try? await settingsStore.addProject(project)
                        await store.reconcile()
                        setSelectedProject(path)
                    }
                    showAddFromPath = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addFromPathText.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func applyAppearance() {
        switch appearanceMode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func presentNewTask() {
        showNewTask = true
    }

    private func handleColumnBackgroundClick(_ column: KanbanCodeColumn) {
        guard column.allowsBoardTaskCreation else { return }
        presentNewTask()
    }

    private func createManualTask(prompt: String, projectPath: String?, title: String? = nil, startImmediately: Bool = false, images: [ImageAttachment] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
            var mutable = img
            return try? mutable.saveToPersistent()
        }
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: startImmediately ? .inProgress : .backlog,
            source: .manual,
            promptBody: trimmed,
            promptImagePaths: imagePaths
        )

        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("manual-task", "Created manual task card=\(link.id.prefix(12)) name='\(name)' project=\(projectPath ?? "nil") startImmediately=\(startImmediately)")

        if startImmediately {
            startCard(cardId: link.id)
        }
    }

    private func createManualTaskAndLaunch(prompt: String, projectPath: String?, title: String? = nil, createWorktree: Bool, runRemotely: Bool, skipPermissions: Bool = true, commandOverride: String? = nil, images: [ImageAttachment] = [], assistant: CodingAssistant = .claude) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
            var mutable = img
            return try? mutable.saveToPersistent()
        }
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: .inProgress,
            source: .manual,
            promptBody: trimmed,
            promptImagePaths: imagePaths,
            assistant: assistant
        )
        let effectivePath = projectPath ?? NSHomeDirectory()

        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("manual-task", "Created & launching task card=\(link.id.prefix(12)) name='\(name)' project=\(effectivePath)")

        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == effectivePath })
            let builtPrompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)

            let wtName: String? = nil
            executeLaunch(cardId: link.id, prompt: builtPrompt, projectPath: effectivePath, worktreeName: wtName, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride, images: images, assistant: assistant)
        }
    }

    // Worktree cleanup removed

    // MARK: - Archive

    private func archiveCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        if card.link.tmuxLink != nil {
            pendingArchiveCardId = cardId
        } else {
            store.dispatch(.archiveCard(cardId: cardId))
        }
    }

    // MARK: - Drag & Drop

    private func handleDrop(cardId: String, to column: KanbanCodeColumn) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        switch CardDropIntent.resolve(card, to: column) {
        case .start:
            startCard(cardId: cardId)
        case .resume:
            resumeCard(cardId: cardId)
        case .archive:
            archiveCard(cardId: cardId)
        case .move:
            store.dispatch(.moveCard(cardId: cardId, to: column))
        case .invalid(let message):
            store.dispatch(.setError(message))
        }
    }

    // MARK: - Start / Resume

    private func startCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let effectivePath = card.link.projectPath ?? NSHomeDirectory()

        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == effectivePath })
            var prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)
            if prompt.isEmpty {
                prompt = card.link.promptBody ?? card.link.name ?? ""
            }

            launchConfig = LaunchConfig(
                cardId: cardId,
                projectPath: effectivePath,
                prompt: prompt,
                promptImagePaths: card.link.promptImagePaths ?? [],
                assistant: card.link.effectiveAssistant
            )
        }
    }

    private func executeLaunch(cardId: String, prompt: String, projectPath: String, worktreeName: String? = nil, runRemotely: Bool = true, skipPermissions: Bool = true, commandOverride: String? = nil, images: [Any] = [], assistant: CodingAssistant = .claude) {
        // IMMEDIATE state update via reducer — no more dual memory+disk writes
        store.dispatch(.launchCard(cardId: cardId, prompt: prompt, projectPath: projectPath, worktreeName: nil, runRemotely: false, commandOverride: commandOverride))
        shouldFocusTerminal = true
        let predictedTmuxName = store.state.links[cardId]?.tmuxLink?.sessionName ?? cardId
        KanbanCodeLog.info("launch", "Starting launch for card=\(cardId.prefix(12)) tmux=\(predictedTmuxName) project=\(projectPath)")

        Task {
            do {
                // Snapshot existing session files for detection
                let sessionFileExt = ".jsonl"
                let configDir = (NSHomeDirectory() as NSString).appendingPathComponent(assistant.configDirName)
                let claudeProjectsDir = (configDir as NSString).appendingPathComponent("projects")
                let encodedProject = SessionFileMover.encodeProjectPath(projectPath)
                let sessionDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedProject)

                let existingFiles = Set(
                    ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir)) ?? [])
                        .filter { $0.hasSuffix(sessionFileExt) }
                )

                let tmuxName = try await launcher.launch(
                    sessionName: predictedTmuxName,
                    projectPath: projectPath,
                    prompt: prompt,
                    shellOverride: nil,
                    extraEnv: [:],
                    commandOverride: commandOverride,
                    skipPermissions: skipPermissions,
                    preamble: nil,
                    assistant: assistant
                )
                KanbanCodeLog.info("launch", "Tmux session created: \(tmuxName)")

                store.dispatch(.launchTmuxReady(cardId: cardId))

                // Send prompt via send-keys after assistant is ready
                if !prompt.isEmpty {
                    // Wait for the assistant to be ready
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(500))
                        if let paneContent = try? await self.tmuxAdapter.capturePane(sessionName: tmuxName),
                           paneContent.contains(assistant.promptCharacter) {
                            break
                        }
                    }
                    try await self.tmuxAdapter.sendPrompt(to: tmuxName, text: prompt)
                }

                // Detect new session by polling for new session file
                var sessionLink: SessionLink?
                for attempt in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(500))
                    let currentFiles = Set(
                        ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir)) ?? [])
                            .filter { $0.hasSuffix(sessionFileExt) }
                    )
                    if let newFile = currentFiles.subtracting(existingFiles).first {
                        let sessionId = (newFile as NSString).deletingPathExtension
                        let sessionPath = (sessionDir as NSString).appendingPathComponent(newFile)
                        KanbanCodeLog.info("launch", "Detected session file after \(attempt+1) attempts: \(sessionId.prefix(8))")
                        sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                        break
                    }
                }

                store.dispatch(.launchCompleted(cardId: cardId, tmuxName: tmuxName, sessionLink: sessionLink))
            } catch {
                KanbanCodeLog.error("launch", "Launch failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.launchFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }

    @State private var pendingDeleteCardId: String?
    @State private var pendingArchiveCardId: String?
    @State private var pendingForkCardId: String?
    @State private var pendingMoveToProject: (cardId: String, projectPath: String, projectName: String)?
    @State private var pendingMoveToFolder: (cardId: String, folderPath: String, parentProjectPath: String, displayName: String)?
    @State private var pendingMigration: (cardId: String, targetAssistant: CodingAssistant)?
    @State private var shouldFocusTerminal = false
    @State private var keyMonitor: Any?

    private func selectFolderForMove(cardId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select folder to move this session to"
        panel.prompt = "Select"

        // Start in the card's current project folder if available
        if let card = store.state.cards.first(where: { $0.id == cardId }),
           let projectPath = card.link.projectPath {
            panel.directoryURL = URL(fileURLWithPath: projectPath)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folderPath = url.path

        // Detect if this folder is nested inside a registered project
        let parentProject = projectList
            .filter { folderPath.hasPrefix($0.path + "/") || folderPath == $0.path }
            .max(by: { $0.path.count < $1.path.count }) // longest prefix = most specific parent

        let parentProjectPath = parentProject?.path ?? folderPath
        let displayName = parentProject?.name ?? (folderPath as NSString).lastPathComponent

        if folderPath == parentProjectPath {
            // Moving to a project root — use the regular move flow
            pendingMoveToProject = (cardId: cardId, projectPath: folderPath, projectName: displayName)
        } else {
            // Moving to a subfolder — use the folder-specific flow
            pendingMoveToFolder = (cardId: cardId, folderPath: folderPath, parentProjectPath: parentProjectPath, displayName: displayName)
        }
    }

    /// Returns assistants the card can be migrated to (excludes current, requires both registered).
    private func migrationTargets(for card: KanbanCodeCard) -> [CodingAssistant] {
        guard card.link.sessionLink != nil else { return [] }
        let current = card.link.effectiveAssistant
        return assistantRegistry.available.filter { $0 != current }
    }

    private func executeMigration(cardId: String, targetAssistant: CodingAssistant) async {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let sessionLink = card.link.sessionLink,
              let sessionPath = sessionLink.sessionPath else { return }
        let sourceAssistant = card.link.effectiveAssistant
        let runRemotely = false
        guard let sourceStore = assistantRegistry.store(for: sourceAssistant),
              let targetStore = assistantRegistry.store(for: targetAssistant) else { return }

        // Mark card as "launching" to prevent the reconciler from touching it
        // while migration is in progress (avoids race where the new session file
        // is discovered before migrateSession updates the sessionId).
        store.dispatch(.beginMigration(cardId: cardId))
        do {
            let result = try await SessionMigrator.migrate(
                sourceSessionPath: sessionPath,
                sourceStore: sourceStore,
                targetStore: targetStore,
                projectPath: card.link.projectPath
            )
            // Update the card's link to point to the new session and kill tmux
            store.dispatch(.migrateSession(
                cardId: cardId,
                newAssistant: targetAssistant,
                newSessionId: result.newSessionId,
                newSessionPath: result.newSessionPath
            ))
            KanbanCodeLog.info("migrate", "Migrated card=\(cardId.prefix(12)) from \(sourceAssistant) to \(targetAssistant), backup=\(result.backupPath)")

            // Resume the session with the new assistant right away
            executeResume(
                cardId: cardId,
                runRemotely: runRemotely,
                skipPermissions: true,
                commandOverride: nil,
                assistant: targetAssistant
            )
        } catch {
            store.dispatch(.migrationFailed(cardId: cardId, error: error.localizedDescription))
            KanbanCodeLog.info("migrate", "Migration failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
        }
    }

    // MARK: - Extra Terminals

    private func createExtraTerminal(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }

        if let tmux = card.link.tmuxLink {
            let existing = tmux.extraSessions ?? []
            let liveTmux = store.state.tmuxSessions
            let baseName = tmux.sessionName
            var n = 1
            while existing.contains("\(baseName)-sh\(n)") || liveTmux.contains("\(baseName)-sh\(n)") { n += 1 }
            let newName = "\(baseName)-sh\(n)"
            store.dispatch(.addExtraTerminal(cardId: cardId, sessionName: newName))
        } else {
            store.dispatch(.createTerminal(cardId: cardId))
        }
    }

    private func resumeCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        let projectPath = card.link.projectPath ?? NSHomeDirectory()

        launchConfig = LaunchConfig(
            cardId: cardId,
            projectPath: projectPath,
            prompt: "",
            isResume: true,
            sessionId: sessionId,
            assistant: card.link.effectiveAssistant
        )
    }

    private func forkCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let sessionPath = card.link.sessionLink?.sessionPath else { return }
        Task {
            do {
                let forkProjectPath = card.link.projectPath
                var targetDir: String? = nil
                if let fp = forkProjectPath {
                    let encoded = SessionFileMover.encodeProjectPath(fp)
                    let home = NSHomeDirectory()
                    targetDir = "\(home)/.claude/projects/\(encoded)"
                }

                let cardStore = assistantRegistry.store(for: card.link.effectiveAssistant) ?? store.sessionStore
                let newSessionId = try await cardStore.forkSession(
                    sessionPath: sessionPath, targetDirectory: targetDir
                )
                let dir = targetDir ?? (sessionPath as NSString).deletingLastPathComponent
                let newPath = (dir as NSString).appendingPathComponent("\(newSessionId).jsonl")
                let newLink = Link(
                    name: (card.link.name ?? card.link.displayTitle) + " (fork)",
                    projectPath: forkProjectPath,
                    column: .waiting,
                    lastActivity: card.link.lastActivity,
                    source: .discovered,
                    sessionLink: SessionLink(sessionId: newSessionId, sessionPath: newPath)
                )
                store.dispatch(.createManualTask(newLink))
                store.dispatch(.selectCard(cardId: newLink.id))
                shouldFocusTerminal = true
            } catch {
                KanbanCodeLog.error("fork", "Fork failed: \(error)")
            }
        }
    }

    private func executeResume(cardId: String, runRemotely: Bool = false, skipPermissions: Bool = true, commandOverride: String?, assistant: CodingAssistant = .claude) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        let projectPath = card.link.projectPath ?? NSHomeDirectory()

        store.dispatch(.resumeCard(cardId: cardId))
        shouldFocusTerminal = true
        KanbanCodeLog.info("resume", "Starting resume for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8))")

        Task {
            do {
                let actualTmuxName = try await launcher.resume(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    shellOverride: nil,
                    extraEnv: [:],
                    commandOverride: commandOverride,
                    skipPermissions: skipPermissions,
                    preamble: nil,
                    assistant: assistant
                )
                KanbanCodeLog.info("resume", "Resume launched for card=\(cardId.prefix(12)) actualTmux=\(actualTmuxName)")

                store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: actualTmuxName))
            } catch {
                KanbanCodeLog.info("resume", "Resume failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.resumeFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }
}

