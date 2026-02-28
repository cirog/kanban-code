import SwiftUI
import KanbanCore

struct SessionHistoryView: View {
    let turns: [ConversationTurn]
    let isLoading: Bool

    var body: some View {
        if isLoading {
            VStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading conversation...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if turns.isEmpty {
            VStack {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No conversation history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(turns, id: \.index) { turn in
                            TurnView(turn: turn)
                                .id(turn.index)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    // Scroll to latest turn
                    if let last = turns.last {
                        proxy.scrollTo(last.index, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct TurnView: View {
    let turn: ConversationTurn

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Role indicator
            Image(systemName: turn.role == "user" ? "person.fill" : "sparkle")
                .font(.caption)
                .foregroundStyle(turn.role == "user" ? .blue : .purple)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(turn.role == "user" ? "You" : "Claude")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(turn.role == "user" ? .blue : .purple)

                    if let timestamp = turn.timestamp {
                        Text(timestamp)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(turn.textPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(turn.role == "user" ? 5 : 10)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(turn.role == "user" ? Color.blue.opacity(0.05) : Color.purple.opacity(0.05))
        )
    }
}
