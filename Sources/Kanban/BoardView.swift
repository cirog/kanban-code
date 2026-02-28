import SwiftUI
import KanbanCore

struct BoardView: View {
    @Bindable var state: BoardState

    var body: some View {
        Group {
            if state.cards.isEmpty && !state.isLoading {
                emptyState
            } else {
                boardContent
            }
        }
    }

    private var boardContent: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(state.visibleColumns, id: \.self) { column in
                    DroppableColumnView(
                        column: column,
                        cards: state.cards(in: column),
                        selectedCardId: $state.selectedCardId,
                        onMoveCard: { cardId, targetColumn in
                            state.moveCard(cardId: cardId, to: targetColumn)
                        },
                        onRenameCard: { cardId, name in
                            state.renameCard(cardId: cardId, name: name)
                        },
                        onArchiveCard: { cardId in
                            state.archiveCard(cardId: cardId)
                        }
                    )
                }
            }
            .padding(16)
        }
        // Error banner overlaid at top
        .overlay(alignment: .top) {
            if let error = state.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { state.error = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.error != nil)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No sessions found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Claude Code sessions will appear here once discovered.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Refresh") {
                Task { await state.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
