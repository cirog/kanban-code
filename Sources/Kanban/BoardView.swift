import SwiftUI
import KanbanCore

struct BoardView: View {
    @Bindable var state: BoardState

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("Kanban")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }

                if let lastRefresh = state.lastRefresh {
                    Text("Updated \(lastRefresh, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Button(action: {
                    Task { await state.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh sessions")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Error banner
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
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }

            // Board + detail panel
            if state.cards.isEmpty && !state.isLoading {
                emptyState
            } else {
                HSplitView {
                    boardContent

                    if let selectedCard = state.cards.first(where: { $0.id == state.selectedCardId }) {
                        CardDetailView(
                            card: selectedCard,
                            onDismiss: { state.selectedCardId = nil }
                        )
                    }
                }
            }
        }
    }

    private var boardContent: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(state.visibleColumns, id: \.self) { column in
                    ColumnView(
                        column: column,
                        cards: state.cards(in: column),
                        selectedCardId: $state.selectedCardId
                    )
                }
            }
            .padding(12)
        }
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
