import SwiftUI
import AppKit
import ClaudeBoardCore

struct BoardView<TerminalContent: View>: View {
    var store: BoardStore
    @State private var dragState = DragState()
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String) -> Void = { _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var canCleanupWorktree: (String) -> Bool = { _ in true }
    var onArchiveCard: (String) -> Void = { _ in }
    var onDeleteCard: (String) -> Void = { _ in }
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String, String) -> Void = { _, _ in }
    var onMoveToFolder: (String) -> Void = { _ in }
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (String, CodingAssistant) -> Void = { _, _ in }
    var onSetProject: (String, String?) -> Void = { _, _ in }  // (cardId, projectId)
    var onRefreshBacklog: () -> Void = {}

    var canDropCard: (ClaudeBoardCard, ClaudeBoardColumn) -> Bool = { _, _ in true }
    var onDropCard: (String, ClaudeBoardColumn) -> Void = { _, _ in }
    var onMergeCards: (String, String) -> Void = { _, _ in }   // (sourceId, targetId)
    var onNewTask: () -> Void = {}
    var onCardClicked: (String) -> Void = { _ in }
    var onColumnBackgroundClick: (ClaudeBoardColumn) -> Void = { _ in }
    var terminalContent: TerminalContent?
    @State private var quickLaunchText: String = ""
    var onQuickLaunch: (String) -> Void = { _ in }

    private var selectedCard: ClaudeBoardCard? {
        guard let id = store.state.selectedCardId else { return nil }
        return store.state.cards.first { $0.id == id }
    }

    var body: some View {
        boardContent
    }

    private var boardContent: some View {
        HStack(alignment: .top, spacing: 6) {
            // Columns + note pad in a VStack (fixed width, note pad underneath)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(store.state.visibleColumns, id: \.self) { column in
                        DroppableColumnView(
                            column: column,
                            cards: store.state.cards(in: column),
                            selectedCardId: Binding(
                                get: { store.state.selectedCardId },
                                set: { store.dispatch(.selectCard(cardId: $0)) }
                            ),
                            dragState: dragState,
                            canDropCard: canDropCard,
                            isRefreshingBacklog: store.state.isRefreshingBacklog,
                            onMoveCard: { cardId, targetColumn in
                                onDropCard(cardId, targetColumn)
                            },
                            onMergeCards: { sourceId, targetId in
                                onMergeCards(sourceId, targetId)
                            },
                            onReorderCard: { cardId, targetCardId, above in
                                store.dispatch(.reorderCard(cardId: cardId, targetCardId: targetCardId, above: above))
                            },
                            onRenameCard: { cardId, name in
                                store.dispatch(.renameCard(cardId: cardId, name: name))
                            },
                            onArchiveCard: { cardId in
                                onArchiveCard(cardId)
                            },
                            onStartCard: onStartCard,
                            onResumeCard: onResumeCard,
                            onForkCard: onForkCard,
                            onCopyResumeCmd: onCopyResumeCmd,
                            onCleanupWorktree: onCleanupWorktree,
                            canCleanupWorktree: canCleanupWorktree,
                            onDeleteCard: onDeleteCard,
                            availableProjects: availableProjects,
                            onMoveToProject: onMoveToProject,
                            onMoveToFolder: onMoveToFolder,
                            enabledAssistants: enabledAssistants,
                            onMigrateAssistant: onMigrateAssistant,
                            onSetProject: onSetProject,
                            onRefreshBacklog: column == .backlog ? onRefreshBacklog : nil,
                            onCardClicked: onCardClicked,
                            onColumnBackgroundClick: onColumnBackgroundClick
                        )
                        .id(column)
                    }
                }
                .frame(maxHeight: 500)
                .clipped()

                notePadView()
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)

            if let terminalContent {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        TextField("Quick launch...", text: $quickLaunchText)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .padding(6)
                            .background(Color.draculaSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onSubmit { submitQuickLaunch() }

                        Button(action: submitQuickLaunch) {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .disabled(quickLaunchText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                    terminalContent
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .id(store.state.selectedCardId ?? "none")
                }
                .layoutPriority(0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .padding(.bottom, 16)
        // Error banner at bottom
        .overlay(alignment: .bottom) {
            if let error = store.state.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.app(.title3))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(error)
                        .font(.app(.body, weight: .medium))
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        store.dispatch(.setError(nil))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color.draculaSurface, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.state.error != nil)
        // Empty board hint
        .overlay {
            if store.state.filteredCards.isEmpty && !store.state.isLoading {
                VStack(spacing: 12) {
                    if let projectPath = store.state.selectedProjectPath {
                        let name = store.state.configuredProjects.first(where: { $0.path == projectPath })?.name
                            ?? (projectPath as NSString).lastPathComponent
                        Text("No sessions yet for \(name)")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions found")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    }
                    Text("Create a new task or start a Claude session to get going.")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)

                    Button(action: onNewTask) {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func notePadView() -> some View {
        let cardId = store.state.selectedCardId
        let link = cardId.flatMap { store.state.links[$0] }

        VStack(spacing: 4) {
            HStack {
                Text("Notes")
                    .font(.app(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cardId, let link {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.notes ?? "", forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)

                    Button {
                        if let tmux = link.tmuxLink?.sessionName,
                           let notes = link.notes, !notes.isEmpty {
                            store.dispatch(.updateNotes(cardId: cardId, notes: notes))
                            Task {
                                let tmuxPath = ShellCommand.findExecutable("tmux") ?? "tmux"
                                let _ = try? await ShellCommand.run(tmuxPath, arguments: ["send-keys", "-t", tmux, notes, "Enter"])
                                await MainActor.run {
                                    store.dispatch(.updateNotes(cardId: cardId, notes: nil))
                                }
                            }
                        }
                    } label: {
                        Label("Push to Terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.plain)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .disabled(link.tmuxLink == nil || (link.notes ?? "").isEmpty)
                }
            }
            .padding(.horizontal, 8)

            TextEditor(text: Binding(
                get: { cardId.flatMap { store.state.links[$0]?.notes } ?? "" },
                set: {
                    if let cardId {
                        store.dispatch(.updateNotes(cardId: cardId, notes: $0.isEmpty ? nil : $0))
                    }
                }
            ))
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color.draculaSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func submitQuickLaunch() {
        let text = quickLaunchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onQuickLaunch(text)
        quickLaunchText = ""
    }
}
