import SwiftUI
import KanbanCore

struct CardDetailView: View {
    let card: KanbanCard
    var onResume: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.displayTitle)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let projectName = card.projectName {
                            Label(projectName, systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let branch = card.link.worktreeBranch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(card.relativeTime)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(16)

            Divider()

            // Tab bar
            Picker("Tab", selection: $selectedTab) {
                Text("History").tag(0)
                Text("Actions").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Content
            switch selectedTab {
            case 0:
                SessionHistoryView(turns: turns, isLoading: isLoadingHistory)
            case 1:
                actionsView
            default:
                EmptyView()
            }
        }
        .frame(minWidth: 350, idealWidth: 400, maxWidth: 500)
        .background(Color(.windowBackgroundColor))
        .task {
            await loadHistory()
        }
    }

    private var actionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onResume) {
                Label("Resume Session", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button(action: copyResumeCommand) {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            if let jsonlPath = card.link.sessionPath {
                Button(action: { copyToClipboard("claude --resume \(card.link.sessionId)") }) {
                    Label("Copy Session ID", systemImage: "number")
                }
                .buttonStyle(.bordered)

                Text(jsonlPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(16)
    }

    private func loadHistory() async {
        guard let path = card.link.sessionPath ?? card.session?.jsonlPath else { return }
        isLoadingHistory = true
        do {
            turns = try await TranscriptReader.readTurns(from: path)
        } catch {
            // Silently fail — empty history is fine
        }
        isLoadingHistory = false
    }

    private func copyResumeCommand() {
        copyToClipboard("claude --resume \(card.link.sessionId)")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
