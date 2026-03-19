import SwiftUI
import ClaudeBoardCore
import MarkdownUI

/// Shared between CardDetailView and ContentView so the toolbar can show
/// the exact same actions menu without duplicating the menu builder.
final class ActionsMenuProvider {
    var builder: (() -> NSMenu)?
}

enum DetailTab: String {
    case terminal, history, prompt, description, summary

    static func initialTab(for card: ClaudeBoardCard) -> DetailTab {
        if card.link.tmuxLink != nil { return .terminal }
        if card.link.sessionLink != nil { return .history }
        if card.link.todoistId != nil { return .description }
        if card.link.promptBody != nil { return .prompt }
        return .history
    }
}

/// Button style that provides hover (brighten) and press (dim + scale) feedback
/// for custom-styled plain buttons.
private struct HoverFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverableBody(configuration: configuration)
    }

    private struct HoverableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .brightness(configuration.isPressed ? -0.08 : isHovered ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .onHover { isHovered = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHovered)
                .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// View modifier that adds hover brightness feedback (for Menu and other non-Button views).
private struct HoverBrightness: ViewModifier {
    var amount: Double = 0.06
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? amount : 0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

struct CardDetailView: View {
    let card: ClaudeBoardCard
    var onResume: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onFork: (_ keepWorktree: Bool) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onUnlink: (Action.LinkType) -> Void = { _ in }
    var onDeleteCard: () -> Void = {}
    var onCreateTerminal: () -> Void = {}
    var onKillTerminal: (String) -> Void = { _ in }
    var onRenameTerminal: (String, String) -> Void = { _, _ in } // (sessionName, label)
    var onReorderTerminal: (String, String?) -> Void = { _, _ in } // (sessionName, beforeSession)
    var onCancelLaunch: () -> Void = {}
    var onAddQueuedPrompt: (QueuedPrompt) -> Void = { _ in }
    var onUpdateQueuedPrompt: (String, String, Bool) -> Void = { _, _, _ in } // promptId, body, sendAuto
    var onRemoveQueuedPrompt: (String) -> Void = { _ in }
    var onSendQueuedPrompt: (String) -> Void = { _ in }
    var onEditingQueuedPrompt: (String?) -> Void = { _ in } // promptId when editing, nil when done
    var onUpdatePrompt: (String, [String]?) -> Void = { _, _ in } // body, imagePaths
    var onSendReplyText: (String) -> Void = { _ in }
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String) -> Void = { _ in }
    var onMoveToFolder: () -> Void = {}
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (CodingAssistant) -> Void = { _ in }
    var onSetLastTab: (String) -> Void = { _ in }
    var actionsMenuProvider: ActionsMenuProvider?
    @Binding var focusTerminal: Bool
    @Binding var isDroppingImage: Bool

    @AppStorage("preferredEditorBundleId") private var editorBundleId: String = "dev.zed.Zed"
    @AppStorage("sessionDetailFontSize") private var sessionDetailFontSize: Double = 12

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var hasMoreTurns = false
    @State private var isLoadingMore = false
    @Binding var selectedTab: DetailTab
    @State private var showRenameSheet = false
    @State private var renameText = ""

    // Checkpoint mode
    @State private var checkpointMode = false
    @State private var checkpointTurn: ConversationTurn?
    @State private var showCheckpointConfirm = false

    // Fork
    @State private var showForkConfirm = false


    // Copy toast
    @State private var copyToast: String?


    // Queued prompts
    @State private var queuedPromptItem: QueuedPromptItem?

    // Edit prompt
    @State private var showEditPromptSheet = false

    // Prompt timeline
    @State private var promptTurns: [ConversationTurn] = []
    @State private var isLoadingPrompts = false
    @State private var promptsCardId: String?

    // Summary tab
    @State private var summaryText: String?
    @State private var isLoadingSummary = false
    @State private var summaryCardId: String?

    // Reply tab refresh
    @State private var replyRefreshId: Int = 0

    // File watcher for real-time history
    @State private var historyWatcherFD: Int32 = -1
    @State private var historyWatcherSource: DispatchSourceFileSystemObject?
    @State private var historyPollTask: Task<Void, Never>?
    @State private var lastReloadTime: Date = .distantPast

    // Multi-terminal
    @State private var selectedTerminalSession: String?
    @State private var knownTerminalCount: Int = 0
    @State private var terminalGrabFocus: Bool = false
    @State private var suppressTerminalFocus: Bool = false
    @State private var tabRenameItem: TabRenameItem?
    @State private var draggingTab: String?
    @State private var dropTargetTab: String?
    @State private var terminalPaths: [String: String] = [:]  // sessionName → last path component
    @State private var pathPollTask: Task<Void, Never>?

    /// Launch lock older than 30s is stale — stop showing spinner, show terminal instead
    private var isLaunchStale: Bool {
        Date.now.timeIntervalSince(card.link.updatedAt) > 30
    }

    let sessionStore: SessionStore

    init(card: ClaudeBoardCard, sessionStore: SessionStore = ClaudeCodeSessionStore(), selectedTab: Binding<DetailTab>, onResume: @escaping () -> Void = {}, onRename: @escaping (String) -> Void = { _ in }, onFork: @escaping (_ keepWorktree: Bool) -> Void = { _ in }, onDismiss: @escaping () -> Void = {}, onUnlink: @escaping (Action.LinkType) -> Void = { _ in }, onDeleteCard: @escaping () -> Void = {}, onCreateTerminal: @escaping () -> Void = {}, onKillTerminal: @escaping (String) -> Void = { _ in }, onRenameTerminal: @escaping (String, String) -> Void = { _, _ in }, onReorderTerminal: @escaping (String, String?) -> Void = { _, _ in }, onCancelLaunch: @escaping () -> Void = {}, onAddQueuedPrompt: @escaping (QueuedPrompt) -> Void = { _ in }, onUpdateQueuedPrompt: @escaping (String, String, Bool) -> Void = { _, _, _ in }, onRemoveQueuedPrompt: @escaping (String) -> Void = { _ in }, onSendQueuedPrompt: @escaping (String) -> Void = { _ in }, onEditingQueuedPrompt: @escaping (String?) -> Void = { _ in }, onUpdatePrompt: @escaping (String, [String]?) -> Void = { _, _ in }, onSendReplyText: @escaping (String) -> Void = { _ in }, availableProjects: [(name: String, path: String)] = [], onMoveToProject: @escaping (String) -> Void = { _ in }, onMoveToFolder: @escaping () -> Void = {}, enabledAssistants: [CodingAssistant] = [], onMigrateAssistant: @escaping (CodingAssistant) -> Void = { _ in }, onSetLastTab: @escaping (String) -> Void = { _ in }, actionsMenuProvider: ActionsMenuProvider? = nil, focusTerminal: Binding<Bool> = .constant(false), isDroppingImage: Binding<Bool> = .constant(false)) {
        self.card = card
        self.sessionStore = sessionStore
        self.onResume = onResume
        self.onRename = onRename
        self.onFork = onFork
        self.onDismiss = onDismiss
        self.onUnlink = onUnlink
        self.onDeleteCard = onDeleteCard
        self.onCreateTerminal = onCreateTerminal
        self.onKillTerminal = onKillTerminal
        self.onRenameTerminal = onRenameTerminal
        self.onReorderTerminal = onReorderTerminal
        self.onCancelLaunch = onCancelLaunch
        self.onAddQueuedPrompt = onAddQueuedPrompt
        self.onUpdateQueuedPrompt = onUpdateQueuedPrompt
        self.onRemoveQueuedPrompt = onRemoveQueuedPrompt
        self.onSendQueuedPrompt = onSendQueuedPrompt
        self.onEditingQueuedPrompt = onEditingQueuedPrompt
        self.onUpdatePrompt = onUpdatePrompt
        self.onSendReplyText = onSendReplyText
        self.availableProjects = availableProjects
        self.onMoveToProject = onMoveToProject
        self.onMoveToFolder = onMoveToFolder
        self.enabledAssistants = enabledAssistants
        self.onMigrateAssistant = onMigrateAssistant
        self.onSetLastTab = onSetLastTab
        self.actionsMenuProvider = actionsMenuProvider
        self._focusTerminal = focusTerminal
        self._isDroppingImage = isDroppingImage
        self._selectedTab = selectedTab
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            normalHeader

            // Content
            switch selectedTab {
            case .terminal:
                terminalView
            case .history:
                VStack(spacing: 0) {
                    HistoryPlusView(turns: turns)
                    HistoryPlusInputBar(onSend: { text in onSendReplyText(text) })
                }
            case .prompt:
                promptTabView
            case .description:
                descriptionTabView
            case .summary:
                summaryTabView
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: card.id) {
            actionsMenuProvider?.builder = { [self] in buildActionsMenu() }
            turns = []
            isLoadingHistory = false
            isLoadingMore = false
            hasMoreTurns = false
            checkpointMode = false
            selectedTerminalSession = nil
            terminalGrabFocus = false
            // Reset tab to a valid one for this card (skip auto-focus)
            suppressTerminalFocus = true
            selectedTab = defaultTab(for: card)
            if selectedTab == .history {
                await loadFullHistory()
                startHistoryWatcher()
            } else {
                await loadHistory()
            }
            // After setup, focus terminal if this card has one and landed on terminal tab
            if selectedTab == .terminal && card.link.tmuxLink != nil {
                terminalGrabFocus = true
            }
        }
        .onChange(of: selectedTab) {
            handleTabChange()
        }
        .onChange(of: card.link.sessionLink?.sessionPath) {
            // When a session path appears (e.g., after launch discovers the session),
            // restart the watcher so history starts updating live.
            guard selectedTab == .history else { return }
            guard card.link.sessionLink?.sessionPath != nil else { return }
            startHistoryWatcher()
            if selectedTab == .history {
                Task { await loadHistory() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeBoardHistoryChanged)) { _ in
            guard selectedTab == .history else { return }
            // Debounce: only reload if >0.5s since last reload
            let now = Date()
            guard now.timeIntervalSince(lastReloadTime) > 0.5 else { return }
            lastReloadTime = now
            if selectedTab == .history {
                Task { await loadHistory() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeBoardSelectTerminalTab)) { notif in
            guard let index = notif.userInfo?["index"] as? Int else { return }
            selectedTab = .terminal
            if index == 0 {
                selectedTerminalSession = nil
            } else {
                let shells = shellSessions
                if index - 1 < shells.count {
                    selectedTerminalSession = shells[index - 1]
                }
            }
            terminalGrabFocus = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeBoardCloseTerminalTab)) { _ in
            guard selectedTab == .terminal else { return }
            // Only close extra shell tabs, not the Claude session
            guard let session = selectedTerminalSession else { return }
            onKillTerminal(session)
            let remaining = shellSessions.filter { $0 != session }
            selectedTerminalSession = remaining.first
        }
        .onChange(of: focusTerminal) {
            if focusTerminal {
                if card.link.tmuxLink != nil {
                    // Terminal already loaded — focus now
                    selectedTab = .terminal
                    terminalGrabFocus = true
                    focusTerminal = false
                }
                // Otherwise wait for tmuxLink to appear (handled below)
            }
        }
        .onChange(of: card.link.tmuxLink?.sessionName) {
            if focusTerminal && card.link.tmuxLink != nil {
                selectedTab = .terminal
                terminalGrabFocus = true
                focusTerminal = false
            }
        }
        .overlay(alignment: .bottom) {
            if let copyToast {
                Text(copyToast)
                    .font(.app(.caption, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.draculaSurface, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copyToast)
        .onDisappear {
            stopHistoryWatcher()
            pathPollTask?.cancel()
            pathPollTask = nil
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSessionDialog(
                currentName: card.link.name ?? card.displayTitle,
                isPresented: $showRenameSheet,
                onRename: onRename
            )
        }
        .sheet(item: $queuedPromptItem) { item in
            QueuedPromptDialog(
                isPresented: Binding(
                    get: { queuedPromptItem != nil },
                    set: { if !$0 { onEditingQueuedPrompt(nil); queuedPromptItem = nil } }
                ),
                existingPrompt: item.existingPrompt,
                assistant: card.link.effectiveAssistant,
                onSave: { body, sendAuto, images in
                    onEditingQueuedPrompt(nil)
                    let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
                        var mutable = img
                        return try? mutable.saveToPersistent()
                    }
                    if let existing = item.existingPrompt {
                        onUpdateQueuedPrompt(existing.id, body, sendAuto)
                    } else {
                        onAddQueuedPrompt(QueuedPrompt(body: body, sendAutomatically: sendAuto, imagePaths: imagePaths))
                    }
                }
            )
        }
        .sheet(isPresented: $showEditPromptSheet) {
            let existingPaths = Set(card.link.promptImagePaths ?? [])
            EditPromptSheet(
                isPresented: $showEditPromptSheet,
                body: card.link.promptBody ?? "",
                existingImagePaths: card.link.promptImagePaths ?? [],
                onSave: { body, images in
                    let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
                        // Already persisted — keep existing path
                        if let path = img.tempPath, existingPaths.contains(path) {
                            return path
                        }
                        var mutable = img
                        return try? mutable.saveToPersistent()
                    }
                    onUpdatePrompt(body, imagePaths)
                }
            )
        }
        .sheet(item: $tabRenameItem) { item in
            RenameTerminalTabDialog(
                currentName: item.currentName,
                isPresented: Binding(
                    get: { tabRenameItem != nil },
                    set: { if !$0 { tabRenameItem = nil } }
                ),
                onRename: { newName in
                    onRenameTerminal(item.sessionName, newName)
                }
            )
        }
        .alert("Fork Session?", isPresented: $showForkConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Fork") { onFork(false) }
        } message: {
            Text("This creates a duplicate session you can resume independently.")
        }
        .alert("Restore to Turn \(checkpointTurn.map { String($0.index + 1) } ?? "")?", isPresented: $showCheckpointConfirm) {
            Button("Cancel", role: .cancel) {
                checkpointTurn = nil
            }
            Button("Restore") { performCheckpoint() }
        } message: {
            Text("Everything after this point will be removed. A .bkp backup will be created.")
        }
    }

    // MARK: - Terminal View

    /// Whether the Claude tab is selected (nil = Claude tab).
    private var isClaudeTabSelected: Bool {
        selectedTerminalSession == nil
    }

    /// The tmux session name for the live Claude terminal, if any.
    private var claudeTmuxSession: String? {
        guard let tmux = card.link.tmuxLink,
              tmux.isShellOnly != true,
              tmux.isPrimaryDead != true else { return nil }
        return tmux.sessionName
    }

    /// All live shell session names (extras + live shell-only primary).
    private var shellSessions: [String] {
        guard let tmux = card.link.tmuxLink else { return [] }
        var sessions = tmux.extraSessions ?? []
        if tmux.isShellOnly == true && tmux.isPrimaryDead != true {
            sessions.insert(tmux.sessionName, at: 0)
        }
        return sessions
    }

    /// All live tmux sessions (Claude + shells) for TerminalContainerView.
    private var allLiveSessions: [String] {
        var sessions: [String] = []
        if let claude = claudeTmuxSession { sessions.append(claude) }
        sessions.append(contentsOf: shellSessions)
        return sessions
    }

    /// The effective tmux session to show in the terminal, based on selected tab.
    private var effectiveActiveSession: String? {
        if isClaudeTabSelected { return claudeTmuxSession }
        return selectedTerminalSession
    }

    /// Whether the tab bar should be visible.
    private var showTabBar: Bool {
        card.link.tmuxLink != nil || card.link.sessionLink != nil ||
        card.link.isLaunching == true
    }

    @ViewBuilder
    private var terminalView: some View {
        if showTabBar {
            // Show launch overlay only if tmux isn't ready yet (no tmuxLink or tmux not alive)
            let isLaunching = card.link.isLaunching == true && !isLaunchStale && effectiveActiveSession == nil
            let showOverlay = isClaudeTabSelected && effectiveActiveSession == nil

            VStack(spacing: 0) {
                // Tab bar: [Claude] [shell tabs...] [+]  ···spacer···  [copy tmux attach]
                HStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            // Assistant tab — always first
                            assistantTab(isSelected: isClaudeTabSelected, isLaunching: isLaunching)

                            // Shell session tabs
                            ForEach(shellSessions, id: \.self) { sessionName in
                                // Drop insertion indicator before this tab
                                if dropTargetTab == sessionName, let drag = draggingTab, drag != sessionName {
                                    tabDropIndicator
                                }

                                shellTab(
                                    sessionName: sessionName,
                                    isSelected: selectedTerminalSession == sessionName
                                )
                                .opacity(draggingTab == sessionName ? 0.3 : 1.0)
                            }

                            // Drop indicator at end (when targeting the + button)
                            if dropTargetTab == "_end_", draggingTab != nil {
                                tabDropIndicator
                            }

                            Button(action: onCreateTerminal) {
                                Image(systemName: "plus")
                                    .font(.app(.caption))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .help("Open new terminal")
                            .dropDestination(for: String.self) { items, _ in
                                guard let dropped = items.first else { return false }
                                onReorderTerminal(dropped, nil)
                                draggingTab = nil
                                dropTargetTab = nil
                                return true
                            } isTargeted: { targeted in
                                dropTargetTab = targeted ? "_end_" : (dropTargetTab == "_end_" ? nil : dropTargetTab)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: dropTargetTab)
                        .onChange(of: dropTargetTab) {
                            // When drag leaves all targets (cancelled or dropped outside),
                            // clear draggingTab after a short delay
                            if dropTargetTab == nil, draggingTab != nil {
                                Task {
                                    try? await Task.sleep(for: .milliseconds(300))
                                    if dropTargetTab == nil {
                                        draggingTab = nil
                                    }
                                }
                            }
                        }
                    }

                    Spacer()

                    // Copy tmux attach — only for live terminal tabs
                    if let activeTmux = effectiveActiveSession {
                        Button {
                            let cmd = "tmux attach -t \(activeTmux)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                    .font(.app(.caption2))
                                Text("Copy tmux attach")
                                    .font(.app(.caption))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Copy: tmux attach -t \(activeTmux)")

                        Button {
                            queuedPromptItem = QueuedPromptItem(existingPrompt: nil)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "text.badge.plus")
                                    .font(.app(.caption2))
                                Text("Queue Prompt")
                                    .font(.app(.caption))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Queue a prompt to send to Claude later")
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 4)

                Divider()

                // Queued prompts bar
                if let prompts = card.link.queuedPrompts, !prompts.isEmpty {
                    QueuedPromptsBar(
                        prompts: prompts,
                        onSendNow: { promptId in onSendQueuedPrompt(promptId) },
                        onEdit: { prompt in
                            onEditingQueuedPrompt(prompt.id)
                            queuedPromptItem = QueuedPromptItem(existingPrompt: prompt)
                        },
                        onRemove: { promptId in onRemoveQueuedPrompt(promptId) }
                    )
                    Divider()
                }

                // Content area: single TerminalContainerView + overlay for non-terminal states
                ZStack {
                    // Always mount the terminal container — never tear down on state changes.
                    // Hiding with opacity instead of `if` prevents SwiftUI from destroying
                    // the NSView during background reconciliation/activity updates.
                    TerminalContainerView(
                        sessions: allLiveSessions,
                        activeSession: effectiveActiveSession ?? allLiveSessions.first ?? "",
                        grabFocus: terminalGrabFocus
                    )
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(allLiveSessions.isEmpty || showOverlay ? 0 : 1)
                    .onChange(of: terminalGrabFocus) {
                        if terminalGrabFocus {
                            // Handle focus directly via TerminalCache — bypasses NSViewRepresentable
                            // update cycle entirely, since grabFocus is excluded from Equatable.
                            let session = effectiveActiveSession ?? allLiveSessions.first ?? ""
                            if !session.isEmpty {
                                TerminalCache.shared.focusTerminal(for: session)
                            }
                            DispatchQueue.main.async { terminalGrabFocus = false }
                        }
                    }

                    // Overlay for non-terminal Claude tab states
                    if showOverlay {
                        assistantTabOverlay(isLaunching: isLaunching)
                    }

                    // Drop target highlight when dragging an image over the window
                    if isDroppingImage && !allLiveSessions.isEmpty {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.app(size: 28))
                                        .foregroundStyle(Color.accentColor)
                                    Text("Drop image to send")
                                        .font(.app(.caption, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            .onChange(of: card.link.tmuxLink) {
                let shells = shellSessions
                let newCount = shells.count + (claudeTmuxSession != nil ? 1 : 0)

                if let selected = selectedTerminalSession, !shells.contains(selected) {
                    // Selected shell was killed — go to next shell or Claude tab
                    selectedTerminalSession = shells.first // nil if no shells left → Claude tab
                } else if newCount > knownTerminalCount, let last = shells.last {
                    // New shell was added — auto-switch to it and focus
                    selectedTerminalSession = last
                    terminalGrabFocus = true
                }

                knownTerminalCount = newCount
                draggingTab = nil
                dropTargetTab = nil
            }
            .onAppear {
                knownTerminalCount = shellSessions.count + (claudeTmuxSession != nil ? 1 : 0)
                startPathPolling()
            }
        } else {
            // No session at all — bare placeholder
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.app(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No session yet")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(action: onCreateTerminal) {
                        Label("New Terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Assistant Tab

    @ViewBuilder
    private func assistantTab(isSelected: Bool, isLaunching: Bool) -> some View {
        let assistant = card.link.effectiveAssistant
        let assistantAlive = claudeTmuxSession != nil
        let isDead = !assistantAlive && !isLaunching
        let tabLabel = assistant.displayName

        HStack(spacing: 0) {
            Button {
                selectedTerminalSession = nil
                if assistantAlive { terminalGrabFocus = true }
            } label: {
                HStack(spacing: 4) {
                    AssistantIcon(assistant: assistant)
                        .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
                    Text(tabLabel)
                        .font(.app(.caption))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isDead ? 0.5 : 1.0)

            // X button only when assistant has a live tmux session
            if assistantAlive {
                Button {
                    if let session = claudeTmuxSession {
                        onKillTerminal(session)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.app(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Stop \(assistant.displayName) session")
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    /// Overlay shown on the assistant tab when there's no live terminal.
    @ViewBuilder
    private func assistantTabOverlay(isLaunching: Bool) -> some View {
        let assistant = card.link.effectiveAssistant
        if isLaunching {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Starting session…")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                Button(action: onCancelLaunch) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if card.link.sessionLink != nil {
            VStack(spacing: 12) {
                AssistantIcon(assistant: assistant)
                    .frame(width: CGFloat(32).scaled, height: CGFloat(32).scaled)
                    .foregroundStyle(Color.primary.opacity(0.3))
                Text("\(assistant.displayName) session ended")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                Button(action: onResume) {
                    Label("Resume \(assistant.displayName)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                AssistantIcon(assistant: assistant)
                    .frame(width: CGFloat(32).scaled, height: CGFloat(32).scaled)
                    .foregroundStyle(Color.primary.opacity(0.3))
                Text("No agent session")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Shell Tab

    /// Blue vertical bar shown at the insertion point during tab drag-and-drop.
    private var tabDropIndicator: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 3, height: 20)
            .padding(.horizontal, -1)
    }

    /// Default shell name (e.g. "zsh", "bash") from the SHELL environment variable.
    private static let userShellName: String = {
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            return (shell as NSString).lastPathComponent
        }
        return "shell"
    }()

    @ViewBuilder
    private func shellTab(sessionName: String, isSelected: Bool) -> some View {
        let customName = card.link.tmuxLink?.tabNames?[sessionName]
        // Priority: 1) user-set custom name, 2) polled cwd folder, 3) shell name
        let displayName: String = customName ?? {
            if let folder = terminalPaths[sessionName], !folder.isEmpty {
                return String(folder.prefix(12))
            }
            return Self.userShellName
        }()

        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.app(.caption2))
                Text(displayName)
                    .font(.app(.caption))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                tabRenameItem = TabRenameItem(sessionName: sessionName, currentName: customName ?? displayName)
            }
            .onTapGesture(count: 1) {
                selectedTerminalSession = sessionName
                terminalGrabFocus = true
            }

            Button {
                onKillTerminal(sessionName)
                if selectedTerminalSession == sessionName {
                    let remaining = shellSessions.filter { $0 != sessionName }
                    selectedTerminalSession = remaining.first
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.app(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close terminal")
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onDrag {
            draggingTab = sessionName
            return NSItemProvider(object: sessionName as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = items.first, dropped != sessionName else { return false }
            onReorderTerminal(dropped, sessionName)
            draggingTab = nil
            dropTargetTab = nil
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetTab = sessionName
            } else if dropTargetTab == sessionName {
                dropTargetTab = nil
            }
        }
        .contextMenu {
            Button("Rename") {
                tabRenameItem = TabRenameItem(sessionName: sessionName, currentName: customName ?? displayName)
            }
        }
    }

    private func defaultTab(for card: ClaudeBoardCard) -> DetailTab {
        // Restore persisted tab if valid for this card
        if let saved = card.link.lastTab, let tab = DetailTab(rawValue: saved) {
            switch tab {
            case .terminal where card.link.tmuxLink != nil: return tab
            case .history: return tab
            default: break
            }
        }
        return DetailTab.initialTab(for: card)
    }


    // MARK: - Todoist Task Tab

    @ViewBuilder
    private var descriptionTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Priority + Labels row
                HStack(spacing: 8) {
                    if let priority = card.link.todoistPriority, priority > 1 {
                        HStack(spacing: 3) {
                            Image(systemName: "flag.fill")
                                .font(.app(size: 10))
                            Text("P\(5 - priority)")
                                .font(.app(.caption, weight: .semibold))
                        }
                        .foregroundStyle(priorityColor(priority))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(priorityColor(priority).opacity(0.15), in: Capsule())
                    }
                    if let labels = card.link.todoistLabels {
                        ForEach(labels, id: \.self) { label in
                            Text(label)
                                .font(.app(.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.draculaCurrentLine, in: Capsule())
                        }
                    }
                    Spacer()
                }

                // Due date
                if let due = card.link.todoistDue {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.app(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Due: \(due)")
                            .font(.app(.callout))
                            .foregroundStyle(.secondary)
                    }
                }

                // Description
                if let desc = card.link.todoistDescription, !desc.isEmpty {
                    Divider()
                    Text(desc)
                        .font(.app(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func priorityColor(_ priority: Int) -> Color {
        switch priority {
        case 4: .red
        case 3: .orange
        case 2: .blue
        default: .secondary
        }
    }

    // MARK: - Prompt Tab

    @ViewBuilder
    private var promptTabView: some View {
        promptTimelineView
    }

    @ViewBuilder
    private var promptTimelineView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if !promptTurns.isEmpty {
                    Text("\(promptTurns.count) prompts")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !promptTurns.isEmpty {
                    Button {
                        let text = promptTurns.map { turn in
                            let ts = turn.timestamp ?? ""
                            return "[\(ts)] \(turn.textPreview)"
                        }.joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if isLoadingPrompts {
                VStack {
                    ProgressView()
                    Text("Loading prompts...")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if promptTurns.isEmpty {
                Text("No prompts found")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Original prompt (from card.link.promptBody) if present
                            if let original = card.link.promptBody, !original.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Original Prompt")
                                        .font(.app(.caption, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(original)
                                        .font(.app(.body))
                                        .textSelection(.enabled)
                                        .lineLimit(5)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.draculaCurrentLine)

                                Divider()
                            }

                            // Chronological prompts
                            ForEach(Array(promptTurns.enumerated()), id: \.offset) { _, turn in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(formatPromptTimestamp(turn.timestamp))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 80, alignment: .trailing)

                                    Text(turn.textPreview)
                                        .font(.app(.body))
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)

                                if turn.index != promptTurns.last?.index {
                                    Divider().padding(.leading, 96)
                                }
                            }

                            Color.clear.frame(height: 1).id("prompts-bottom")
                        }
                    }
                    .onAppear {
                        scrollPromptsToBottom(proxy: proxy)
                    }
                    .onChange(of: promptTurns.count) {
                        scrollPromptsToBottom(proxy: proxy)
                    }
                }
            }
        }
        .task(id: card.id) {
            await loadPrompts()
        }
    }

    private func scrollPromptsToBottom(proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo("prompts-bottom", anchor: .bottom)
        }
    }

    private func loadPrompts() async {
        let paths = allSessionPaths
        guard !paths.isEmpty else {
            promptTurns = []
            return
        }
        guard promptsCardId != card.id else { return } // already loaded
        isLoadingPrompts = true
        promptsCardId = card.id

        var allTurns: [ConversationTurn] = []
        for path in paths {
            for await turn in TranscriptReader.streamAllTurns(from: path) {
                allTurns.append(turn)
            }
        }

        promptTurns = allTurns.filter { turn in
            turn.role == "user" && !turn.textPreview.hasPrefix("[tool result")
        }
        isLoadingPrompts = false
    }

    private func formatPromptTimestamp(_ timestamp: String?) -> String {
        guard let timestamp, !timestamp.isEmpty else { return "" }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: timestamp) else {
            // Try without fractional seconds
            iso.formatOptions = [.withInternetDateTime]
            guard let date = iso.date(from: timestamp) else { return "" }
            return formatDate(date)
        }
        return formatDate(date)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MMM dd, HH:mm"
        }
        return formatter.string(from: date)
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private var summaryTabView: some View {
        VStack {
            if isLoadingSummary {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Generating summary...")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary = summaryText, summaryCardId == card.id {
                MarkdownWebView(markdown: summary)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Generate a summary of this session")
                        .font(.app(.body))
                        .foregroundStyle(.secondary)
                    Button("Generate Summary") {
                        loadSummary()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadSummary() {
        guard let sessionPath = card.link.sessionLink?.sessionPath else { return }
        isLoadingSummary = true
        summaryCardId = card.id

        Task.detached { [cardId = card.id] in
            // Read last 10 turns
            let result = try? await TranscriptReader.readTail(from: sessionPath, maxTurns: 10)
            let turns = result?.turns ?? []

            let transcript = turns.map { turn in
                let role = turn.role == "user" ? "User" : "Assistant"
                return "[\(role)] \(turn.textPreview)"
            }.joined(separator: "\n\n")

            guard !transcript.isEmpty else {
                await MainActor.run {
                    summaryText = "No conversation turns found."
                    isLoadingSummary = false
                }
                return
            }

            let prompt = """
            [CB-SUMMARY] Analyze this Claude Code session. The user's original goal was the first message. Provide:

            ## Goal
            What the user wanted to accomplish (1 sentence)

            ## Journey
            Key steps taken, decisions made, problems encountered (3-5 bullets)

            ## Current State
            What's been accomplished so far

            ## Next Steps
            What remains to be done (if anything)

            Conversation:
            \(transcript)
            """

            // Run claude CLI for summary
            do {
                let claudePath = ShellCommand.findExecutable("claude") ?? "/usr/local/bin/claude"
                let output = try await ShellCommand.run(claudePath, arguments: ["-p", "--model", "sonnet", prompt])
                await MainActor.run {
                    if summaryCardId == cardId {
                        summaryText = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    isLoadingSummary = false
                }
            } catch {
                await MainActor.run {
                    if summaryCardId == cardId {
                        summaryText = "Summary failed: \(error.localizedDescription)"
                    }
                    isLoadingSummary = false
                }
            }
        }
    }

    /// Convert HTML img tags to Markdown image syntax so MarkdownUI can render them.
    private func htmlToMarkdownImages(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\s+[^>]*?src\s*=\s*"([^"]+)"[^>]*?/?>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }

        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let srcRange = Range(match.range(at: 1), in: result) else { continue }
            let src = String(result[srcRange])

            var alt = "image"
            if let altRegex = try? NSRegularExpression(pattern: #"alt\s*=\s*"([^"]*)""#, options: .caseInsensitive),
               let altMatch = altRegex.firstMatch(in: String(result[fullRange]), range: NSRange(0..<result[fullRange].count)),
               let altRange = Range(altMatch.range(at: 1), in: String(result[fullRange])) {
                let extracted = String(String(result[fullRange])[altRange])
                if !extracted.isEmpty { alt = extracted }
            }

            result.replaceSubrange(fullRange, with: "![\(alt)](\(src))")
        }

        return result
    }

    // MARK: - Normal Header (collapsed inspector)

    @ViewBuilder
    private var normalHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(card.displayTitle)
                    .font(.app(.headline))
                    .textCase(nil)
                    .lineLimit(2)
                    .layoutPriority(0)

                Button(action: { showRenameSheet = true }) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Rename")

                if card.link.cardLabel == .session {
                    Text(card.relativeTime)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if card.link.tmuxLink == nil {
                        let hasSession = card.link.sessionLink != nil
                        let isStart = card.column == .backlog || !hasSession
                        Button(action: onResume) {
                            Label(isStart ? "Start" : "Resume", systemImage: "play.fill")
                                .font(.app(size: 13))
                                .foregroundStyle(isStart ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background((isStart ? Color.green : Color.blue).opacity(0.08), in: Capsule())
                                .background(Color.draculaSurface, in: Capsule())
                        }
                        .buttonStyle(HoverFeedbackStyle())
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .help(isStart ? "Start work on this task" : "Resume session")
                    }

                    if let path = card.link.projectPath {
                        Button {
                            EditorDiscovery.open(path: path, bundleId: editorBundleId)
                        } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.app(size: 13))
                                .frame(width: CGFloat(36).scaled, height: CGFloat(36).scaled)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .modifier(HoverBrightness())
                        .help("Open in editor")
                    }

                    actionsMenuButton
                        .glassEffect(.regular, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .modifier(HoverBrightness())
                        .help("More actions")
                }
                .fixedSize()
            }

            if card.link.cardLabel != .session {
                HStack(spacing: 6) {
                    CardLabelBadge(label: card.link.cardLabel)
                    Spacer()
                    Text(card.relativeTime)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let projectPath = card.link.projectPath {
                    copyableRow(icon: "folder.badge.gearshape", text: projectPath)
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    SessionIdRow(sessionId: sessionId, assistant: card.link.effectiveAssistant)
                }
            }
        }
        .padding(16)

        Divider()

        // Tab bar
        HStack {
            Picker("", selection: $selectedTab) {
                Text("Terminal").tag(DetailTab.terminal)
                Text("History").tag(DetailTab.history)
                if card.link.promptBody != nil || card.link.sessionLink != nil {
                    Text("Prompts").tag(DetailTab.prompt)
                }
                if card.link.todoistId != nil { Text("Task").tag(DetailTab.description) }
                if card.link.sessionLink != nil { Text("Summary").tag(DetailTab.summary) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var actionsMenuButton: some View {
        NSMenuButton {
            Image(systemName: "ellipsis")
                .font(.app(.caption))
                .frame(width: CGFloat(36).scaled, height: CGFloat(36).scaled)
                .contentShape(Circle())
        } menuItems: {
            buildActionsMenu()
        }
    }

    private func buildActionsMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addActionItem("Rename", image: "pencil") { [self] in showRenameSheet = true }

        let forkItem = menu.addActionItem("Fork Session", image: "arrow.branch") { [self] in showForkConfirm = true }
        forkItem.isEnabled = card.link.sessionLink?.sessionPath != nil

        let cpItem = menu.addActionItem("Checkpoint / Restore", image: "clock.arrow.circlepath") { [self] in
            checkpointMode = true
            selectedTab = .history
        }
        cpItem.isEnabled = card.link.sessionLink?.sessionPath != nil && !turns.isEmpty

        menu.addItem(NSMenuItem.separator())

        menu.addActionItem("Copy Resume Command", image: "doc.on.doc") { [self] in copyResumeCommand() }
        menu.addActionItem("Copy Card ID", image: "number") { [self] in copyToClipboard(card.id) }

        if let sessionId = card.link.sessionLink?.sessionId {
            let sessionItem = menu.addActionItem("Copy Session ID") { [self] in copyToClipboard(sessionId) }
            if let img = AssistantIcon.menuImage(for: card.link.effectiveAssistant) {
                sessionItem.image = img
            }
        }

        if let tmux = card.link.tmuxLink?.sessionName {
            menu.addActionItem("Copy Tmux Command", image: "terminal") { [self] in copyToClipboard("tmux attach -t \(tmux)") }
        }

        if card.link.sessionLink != nil {
            let currentPath = card.link.projectPath
            let otherProjects = availableProjects.filter { $0.path != currentPath }
            menu.addItem(NSMenuItem.separator())
            let moveItem = NSMenuItem(title: "Move to Project", action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "folder.badge.arrow.forward", accessibilityDescription: nil)
            let submenu = NSMenu()
            for project in otherProjects {
                let item = submenu.addActionItem(project.name) { [self] in onMoveToProject(project.path) }
                _ = item
            }
            if !otherProjects.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            submenu.addActionItem("Select Folder...") { [self] in onMoveToFolder() }
            moveItem.submenu = submenu
            menu.addItem(moveItem)
        }

        if card.link.sessionLink != nil {
            let migrationTargets = enabledAssistants.filter { $0 != card.link.effectiveAssistant }
            if !migrationTargets.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let migrateItem = NSMenuItem(title: "Migrate to Assistant", action: nil, keyEquivalent: "")
                migrateItem.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)
                let migrateSubmenu = NSMenu()
                for target in migrationTargets {
                    let item = migrateSubmenu.addActionItem(target.displayName) { [self] in onMigrateAssistant(target) }
                    _ = item
                }
                migrateItem.submenu = migrateSubmenu
                menu.addItem(migrateItem)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addActionItem("Delete Card", image: "trash") { [self] in onDeleteCard(); onDismiss() }

        return menu
    }

    // MARK: - History loading

    /// All session paths in chronological order (previous sessions + current).
    private var allSessionPaths: [String] {
        var paths = card.link.sessionLink?.previousSessionPaths ?? []
        if let current = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath {
            paths.append(current)
        }
        return paths
    }

    /// Whether this card has chained sessions (slug continuation via --resume).
    private var hasChainedSessions: Bool {
        !(card.link.sessionLink?.previousSessionPaths ?? []).isEmpty
    }

    private static let pageSize = 80

    private func loadFullHistory() async {
        guard let currentPath = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        isLoadingHistory = true
        var allTurns: [ConversationTurn] = []
        // Load previous chained sessions first (oldest to newest)
        for prevPath in card.link.sessionLink?.previousSessionPaths ?? [] {
            if let prev = try? await TranscriptReader.readTurns(from: prevPath) {
                allTurns.append(contentsOf: prev)
            }
        }
        // Load current session
        if let current = try? await TranscriptReader.readTurns(from: currentPath) {
            allTurns.append(contentsOf: current)
        }
        // Re-index turns sequentially so scroll/search works correctly
        turns = allTurns.enumerated().map { idx, turn in
            ConversationTurn(
                index: idx,
                lineNumber: turn.lineNumber,
                role: turn.role,
                textPreview: turn.textPreview,
                timestamp: turn.timestamp,
                contentBlocks: turn.contentBlocks
            )
        }
        hasMoreTurns = false
        isLoadingHistory = false
    }

    private func loadHistory() async {
        // Chained sessions: always use full load (re-indexes across files)
        if hasChainedSessions {
            await loadFullHistory()
            return
        }
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        if turns.isEmpty { isLoadingHistory = true }
        // Preserve expanded window: if user loaded more than pageSize, keep that many
        let loadCount = max(Self.pageSize, turns.count)
        do {
            // Claude uses JSONL — paginated loading with stable incremental reload
            let result = try await TranscriptReader.readTail(from: path, maxTurns: loadCount)
            if turns.isEmpty {
                // Initial load — use the full result
                turns = result.turns
                hasMoreTurns = result.hasMore
            } else {
                // Live reload — only append new turns so existing views stay stable
                let lastLineNumber = turns.last?.lineNumber ?? 0
                let newTurns = result.turns.filter { $0.lineNumber > lastLineNumber }
                if !newTurns.isEmpty {
                    turns.append(contentsOf: newTurns)
                }
            }
        } catch {
            // Silently fail — empty history is fine
        }
        isLoadingHistory = false
    }

    private func loadMoreHistory() async {
        guard !hasChainedSessions else { return } // Full history already loaded
        guard hasMoreTurns, !isLoadingMore else { return }
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        guard let firstTurn = turns.first else { return }

        isLoadingMore = true
        let rangeStart = max(0, firstTurn.index - Self.pageSize)
        let rangeEnd = firstTurn.index

        do {
            let earlier = try await TranscriptReader.readRange(from: path, turnRange: rangeStart..<rangeEnd)
            turns = earlier + turns
            hasMoreTurns = rangeStart > 0
        } catch {
            // Silently fail
        }
        isLoadingMore = false
    }

    /// Load turns around a specific turn index (for search match navigation).
    /// Loads a page-sized chunk around the target, merging with existing turns.
    private func loadAroundTurn(_ targetIndex: Int) async {
        guard !hasChainedSessions else { return } // Full history already loaded
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        isLoadingMore = true

        let halfPage = Self.pageSize / 2
        let rangeStart = max(0, targetIndex - halfPage)
        let rangeEnd = targetIndex + halfPage

        do {
            let chunk = try await TranscriptReader.readRange(from: path, turnRange: rangeStart..<rangeEnd)
            var byIndex: [Int: ConversationTurn] = [:]
            for t in turns { byIndex[t.index] = t }
            for t in chunk { byIndex[t.index] = t }
            turns = byIndex.values.sorted { $0.index < $1.index }
            hasMoreTurns = (turns.first?.index ?? 0) > 0
        } catch { }
        isLoadingMore = false
    }

    // MARK: - File watcher

    private func startHistoryWatcher() {
        stopHistoryWatcher()
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        historyWatcherFD = fd

        let source = Self.makeHistorySource(fd: fd)
        historyWatcherSource = source

        // Periodic poll as fallback (every 3s) in case DispatchSource misses events
        historyPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, selectedTab == .history else { break }
                await loadHistory()
            }
        }
    }

    /// Must be nonisolated so GCD closures don't inherit @MainActor isolation (causes crash).
    private nonisolated static func makeHistorySource(fd: Int32) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .claudeBoardHistoryChanged, object: nil)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func stopHistoryWatcher() {
        historyWatcherSource?.cancel()
        historyWatcherSource = nil
        historyWatcherFD = -1
        historyPollTask?.cancel()
        historyPollTask = nil
    }

    // MARK: - Tab change handler

    private func handleTabChange() {
        // Persist tab selection
        onSetLastTab(selectedTab.rawValue)

        if selectedTab == .terminal {
            if suppressTerminalFocus {
                suppressTerminalFocus = false
            } else {
                terminalGrabFocus = true
            }
        }
        if selectedTab == .history {
            Task { await loadFullHistory() }
            startHistoryWatcher()
        } else {
            stopHistoryWatcher()
        }
    }

    // MARK: - Terminal path polling

    /// Polls tmux for each managed session's current working directory every 3 seconds.
    /// Uses tmux `list-panes` with the session name to get `pane_current_path`.
    private func startPathPolling() {
        pathPollTask?.cancel()
        // Capture the base session name — stable for the card's lifetime.
        guard let baseName = card.link.tmuxLink?.sessionName else { return }
        pathPollTask = Task {
            let tmux = TerminalCache.tmuxPath
            while !Task.isCancelled {
                // Query panes for extra shell sessions (base-sh1, base-sh2, ...).
                // Skip the primary session — it always shows the assistant name.
                if let result = try? await ShellCommand.run(
                    tmux, arguments: [
                        "list-panes", "-a",
                        "-F", "#{session_name}\t#{pane_current_path}",
                        "-f", "#{m:\(baseName)-*,#{session_name}}"
                    ]
                ) {
                    let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    for line in output.components(separatedBy: "\n") where !line.isEmpty {
                        let parts = line.components(separatedBy: "\t")
                        guard parts.count >= 2 else { continue }
                        let session = parts[0]
                        let folder = (parts[1] as NSString).lastPathComponent
                        if !folder.isEmpty && folder != terminalPaths[session] {
                            terminalPaths[session] = folder
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    // MARK: - Fork (handled by onFork callback)

    // MARK: - Checkpoint

    private func performCheckpoint() {
        guard let path = card.link.sessionLink?.sessionPath,
              let turn = checkpointTurn else { return }
        Task {
            do {
                try await sessionStore.truncateSession(sessionPath: path, afterTurn: turn)
                checkpointMode = false
                checkpointTurn = nil
                await loadHistory()
            } catch {
                // Could show error toast
            }
        }
    }

    private func copyResumeCommand() {
        var cmd = ""
        if let projectPath = card.link.projectPath {
            cmd += "cd \(projectPath) && "
        }
        if let sessionId = card.link.sessionLink?.sessionId {
            cmd += "claude --resume \(sessionId)"
        } else {
            cmd += "# no session yet"
        }
        copyToClipboard(cmd)
    }

    /// Property row: icon + "Label: value", all secondary color, with optional link and × buttons.
    private func linkPropertyRow(
        icon: String, label: String, value: String,
        color: Color = .secondary,
        url: String? = nil,
        onUnlink: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Label {
                Text("\(label): \(value)")
            } icon: {
                Image(systemName: icon)
            }
            .font(.app(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

            if let url, let parsed = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(parsed)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open in browser")

                Button {
                    copyToClipboard(url)
                    showCopyToast("\(label) link copied to clipboard")
                } label: {
                    Image(systemName: "link")
                        .font(.app(.caption2))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Copy link")
            }

            if let onUnlink {
                Button {
                    onUnlink()
                } label: {
                    Image(systemName: "xmark")
                        .font(.app(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove link")
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showCopyToast(_ message: String) {
        copyToast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copyToast == message { copyToast = nil }
        }
    }

    private func copyableRow(icon: String, text: String) -> some View {
        CopyableRow(icon: icon, text: text)
    }
}

private struct SessionIdRow: View {
    let sessionId: String
    let assistant: CodingAssistant
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                AssistantIcon(assistant: assistant)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
                    .foregroundStyle(Color.primary.opacity(0.4))
                Text(sessionId)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sessionId, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }
}

private struct CopyableRow: View {
    let icon: String
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Label(text, systemImage: icon)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }
}

// MARK: - Compact Markdown Theme

@MainActor
extension Theme {
    /// Smaller text, tighter spacing, no opaque background on code blocks.
    static let compact = Theme()
        .text { FontSize(.em(0.87)) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.82))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.25)); FontWeight(.semibold) }
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.12)); FontWeight(.semibold) }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.0)); FontWeight(.semibold) }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: 0, bottom: 8)
        }
        .codeBlock { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.8))
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .markdownMargin(top: 4, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
}

/// Native rename dialog sheet.
struct RenameSessionDialog: View {
    let currentName: String
    @Binding var isPresented: Bool
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = currentName
        }
    }
}

/// Rename dialog for terminal tabs.
private struct TabRenameItem: Identifiable {
    let id = UUID()
    let sessionName: String
    let currentName: String
}

private struct QueuedPromptItem: Identifiable {
    let id = UUID()
    let existingPrompt: QueuedPrompt?
}

struct RenameTerminalTabDialog: View {
    let currentName: String
    @Binding var isPresented: Bool
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Terminal Tab")
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField("Tab name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = currentName
        }
    }
}

// MARK: - NSMenuButton (SwiftUI button that shows an NSMenu anchored below it)

/// A SwiftUI view that renders custom SwiftUI content but on click shows an NSMenu
/// anchored directly below the view — no mouse-position hacks needed.
struct NSMenuButton<Label: View>: NSViewRepresentable {
    let label: Label
    let menuItems: () -> NSMenu

    init(@ViewBuilder label: () -> Label, menuItems: @escaping () -> NSMenu) {
        self.label = label()
        self.menuItems = menuItems
    }

    func makeNSView(context: Context) -> NSMenuButtonNSView {
        let view = NSMenuButtonNSView()
        view.menuBuilder = menuItems
        // Embed the SwiftUI label as a hosting view
        let host = NSHostingView(rootView: label)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func updateNSView(_ nsView: NSMenuButtonNSView, context: Context) {
        nsView.menuBuilder = menuItems
        // Update SwiftUI label
        if let host = nsView.subviews.first as? NSHostingView<Label> {
            host.rootView = label
        }
    }
}

final class NSMenuButtonNSView: NSView {
    var menuBuilder: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        // Anchor below this view — nil positioning avoids pre-selecting an item
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }
}

// MARK: - NSMenu closure helper

final class NSMenuActionItem: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

extension NSMenu {
    @discardableResult
    func addActionItem(_ title: String, image: String? = nil, handler: @escaping () -> Void) -> NSMenuItem {
        let target = NSMenuActionItem(handler)
        let item = NSMenuItem(title: title, action: #selector(NSMenuActionItem.invoke), keyEquivalent: "")
        item.target = target
        item.representedObject = target // prevent dealloc
        if let image, let img = NSImage(systemSymbolName: image, accessibilityDescription: nil) {
            item.image = img
        }
        addItem(item)
        return item
    }
}

// MARK: - Edit Prompt Sheet

private struct EditPromptSheet: View {
    @Binding var isPresented: Bool
    @State private var text: String
    @State private var images: [ImageAttachment]
    let existingImagePaths: [String]
    let onSave: (String, [ImageAttachment]) -> Void

    init(isPresented: Binding<Bool>, body: String, existingImagePaths: [String], onSave: @escaping (String, [ImageAttachment]) -> Void) {
        self._isPresented = isPresented
        self._text = State(initialValue: body)
        self.existingImagePaths = existingImagePaths
        self.onSave = onSave
        let loaded = existingImagePaths.compactMap { ImageAttachment.fromPath($0) }
        self._images = State(initialValue: loaded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Prompt")
                .font(.app(.title3))
                .fontWeight(.semibold)

            PromptSection(
                text: $text,
                images: $images,
                placeholder: "Describe what you want Claude to do...",
                maxHeight: 300,
                onSubmit: save
            )

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Separate: images that already have a persistent path vs new ones
        var allImages: [ImageAttachment] = []
        for img in images {
            if let path = img.tempPath, existingImagePaths.contains(path) {
                // Already persisted — pass through as-is
                allImages.append(img)
            } else {
                allImages.append(img)
            }
        }
        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines), allImages)
        isPresented = false
    }
}


