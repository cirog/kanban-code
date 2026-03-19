import SwiftUI
import ClaudeBoardCore

// MARK: - Data Models

struct ClaudeProcessInfo: Identifiable {
    let id: Int // PID
    let command: String
    let sessionId: String?
    let cardId: String?
    let cardTitle: String?
}

// MARK: - Process Manager View

struct ProcessManagerView: View {
    let store: BoardStore
    @Binding var isPresented: Bool
    var onSelectCard: (String) -> Void = { _ in }

    enum Tab: String, CaseIterable {
        case tmux = "Tmux"
        case claude = "Claude"
    }

    @State private var selectedTab: Tab = .tmux
    @State private var tmuxSessions: [TmuxSession] = []
    @State private var claudeProcesses: [ClaudeProcessInfo] = []
    @State private var isLoading = false
    @State private var selectedTmuxIds: Set<String> = []
    @State private var selectedClaudeIds: Set<Int> = []
    private let tmuxAdapter = TmuxAdapter()

    private let tmuxFound = ShellCommand.findExecutable("tmux") != nil

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .tmux: tmuxTab
                case .claude: claudeTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom bar
            HStack {
                if selectedTab == .tmux {
                    let ownedCount = tmuxSessions.filter { isOurSession($0) }.count
                    if ownedCount > 0 {
                        Button("Kill All Managed (\(ownedCount))") {
                            Task { await killAllOwned() }
                        }
                    }
                    if !selectedTmuxIds.isEmpty {
                        Button("Kill Selected (\(selectedTmuxIds.count))") {
                            Task { await killSelected() }
                        }
                    }
                } else if selectedTab == .claude {
                    if !selectedClaudeIds.isEmpty {
                        Button("Kill Selected (\(selectedClaudeIds.count))") {
                            Task { await killSelectedClaude() }
                        }
                    }
                }
                Spacer()
                Button {
                    Task { await loadAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Refresh")
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 680, height: 450)
        .task { await loadAll() }
    }

    // MARK: - Tab Labels

    private func tabLabel(_ tab: Tab) -> String {
        switch tab {
        case .tmux: "Tmux (\(tmuxSessions.count))"
        case .claude: "Claude (\(claudeProcesses.count))"
        }
    }

    // MARK: - Tmux Tab

    private var tmuxTab: some View {
        VStack(spacing: 0) {
            if !tmuxFound {
                binaryNotFoundBanner("tmux")
            }
            Table(tmuxSessions, selection: $selectedTmuxIds) {
            TableColumn("") { session in
                Circle()
                    .fill(session.attached ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            .width(16)

            TableColumn("Name") { session in
                HStack(spacing: 4) {
                    Text(session.name)
                        .lineLimit(1)
                    if isOurSession(session) {
                        Text("managed")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .width(min: 150, ideal: 200)

            TableColumn("Path") { session in
                Text(abbreviatePath(session.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Card") { session in
                if let (cardId, cardTitle) = cardForTmux(session.name) {
                    Button {
                        onSelectCard(cardId)
                        isPresented = false
                    } label: {
                        Text(cardTitle)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Go to card")
                }
            }
            .width(min: 80, ideal: 140)

            TableColumn("") { session in
                Button {
                    Task { await killTmuxSession(session) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Kill session")
            }
            .width(24)
        }
        }
    }

    // MARK: - Claude Tab

    private let claudeFound = ShellCommand.findExecutable("claude") != nil

    private var claudeTab: some View {
        VStack(spacing: 0) {
            if !claudeFound {
                binaryNotFoundBanner("claude")
            }
            Table(claudeProcesses, selection: $selectedClaudeIds) {
            TableColumn("PID") { process in
                Text("\(process.id)")
                    .monospacedDigit()
            }
            .width(60)

            TableColumn("Command") { process in
                Text(process.command)
                    .lineLimit(1)
            }
            .width(min: 200, ideal: 300)

            TableColumn("Session") { process in
                if let sid = process.sessionId {
                    Text(String(sid.prefix(8)))
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            .width(80)

            TableColumn("Card") { process in
                if let cardId = process.cardId, let title = process.cardTitle {
                    Button {
                        onSelectCard(cardId)
                        isPresented = false
                    } label: {
                        Text(title)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Go to card")
                }
            }
            .width(min: 80, ideal: 140)
        }
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        defer { isLoading = false }

        async let t: Void = loadTmux()
        async let c: Void = loadClaude()
        _ = await (t, c)
    }

    private func loadTmux() async {
        tmuxSessions = (try? await tmuxAdapter.listSessions()) ?? []
    }

    private func loadClaude() async {
        claudeProcesses = await discoverClaudeProcesses()
    }

    // MARK: - Claude Process Discovery

    private func discoverClaudeProcesses() async -> [ClaudeProcessInfo] {
        // Use pgrep -fl to find claude processes directly — avoids pipe deadlock
        // with large `ps -eo` output (>64KB pipe buffer).
        guard let result = try? await ShellCommand.run(
            "/usr/bin/pgrep", arguments: ["-fl", "claude"]
        ), result.succeeded else { return [] }

        var processes: [ClaudeProcessInfo] = []
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let cmd = String(parts[1])

            // Check that the command IS claude, not just mentions it as an arg
            let executable = cmd.split(separator: " ").first.map(String.init) ?? ""
            let isClaude = executable == "claude" || executable.hasSuffix("/claude")
            let isClaudeNode = cmd.hasPrefix("node ") && cmd.contains("/claude")
            guard isClaude || isClaudeNode else { continue }

            // Extract --resume <sessionId> if present
            var sessionId: String?
            if let range = cmd.range(of: "--resume ") {
                let afterResume = cmd[range.upperBound...]
                sessionId = String(afterResume.prefix(while: { !$0.isWhitespace }))
            }

            // Match to card
            let (cardId, cardTitle) = cardForSession(sessionId)

            processes.append(ClaudeProcessInfo(
                id: pid,
                command: cmd,
                sessionId: sessionId,
                cardId: cardId,
                cardTitle: cardTitle
            ))
        }
        return processes
    }

    // MARK: - Card Matching

    private func cardForTmux(_ sessionName: String) -> (String, String)? {
        for card in store.state.cards {
            if let tmux = card.link.tmuxLink,
               tmux.allSessionNames.contains(sessionName) {
                return (card.id, card.displayTitle)
            }
        }
        return nil
    }

    private func cardForSession(_ sessionId: String?) -> (String?, String?) {
        guard let sessionId else { return (nil, nil) }
        for card in store.state.cards {
            if card.link.sessionLink?.sessionId == sessionId {
                return (card.id, card.displayTitle)
            }
        }
        return (nil, nil)
    }

    // MARK: - Tmux Actions

    private func isOurSession(_ session: TmuxSession) -> Bool {
        session.name.contains("card_")
    }

    private func killTmuxSession(_ session: TmuxSession) async {
        try? await tmuxAdapter.killSession(name: session.name)
        TerminalCache.shared.remove(session.name)
        // If it's our session, find and update the card
        if isOurSession(session) {
            cleanupCardTmux(sessionName: session.name)
        }
        await loadTmux()
    }

    private func killSelected() async {
        for id in selectedTmuxIds {
            if let session = tmuxSessions.first(where: { $0.id == id }) {
                try? await tmuxAdapter.killSession(name: session.name)
                TerminalCache.shared.remove(session.name)
                if isOurSession(session) {
                    cleanupCardTmux(sessionName: session.name)
                }
            }
        }
        selectedTmuxIds.removeAll()
        await loadTmux()
    }

    private func killAllOwned() async {
        for session in tmuxSessions where isOurSession(session) {
            try? await tmuxAdapter.killSession(name: session.name)
            TerminalCache.shared.remove(session.name)
            cleanupCardTmux(sessionName: session.name)
        }
        await loadTmux()
    }

    private func cleanupCardTmux(sessionName: String) {
        for card in store.state.cards {
            guard let tmux = card.link.tmuxLink else { continue }
            if tmux.sessionName == sessionName {
                // Primary session killed — clear entire tmuxLink
                store.dispatch(.unlinkFromCard(cardId: card.id, linkType: .tmux))
                return
            }
            if tmux.extraSessions?.contains(sessionName) == true {
                // Extra session killed
                store.dispatch(.killTerminal(cardId: card.id, sessionName: sessionName))
                return
            }
        }
    }

    // MARK: - Claude Actions

    private func killSelectedClaude() async {
        for pid in selectedClaudeIds {
            kill(Int32(pid), SIGTERM)
        }
        selectedClaudeIds.removeAll()
        // Brief delay for processes to exit
        try? await Task.sleep(for: .milliseconds(500))
        await loadClaude()
    }

    // MARK: - Helpers

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func binaryNotFoundBanner(_ name: String) -> some View {
        let home = NSHomeDirectory()
        let paths = [
            "~/.claude/local", "~/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ].map { "\($0)/\(name)" }
            .map { $0.replacingOccurrences(of: home, with: "~") }

        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) not found")
                    .font(.app(.callout))
                    .fontWeight(.medium)
                Text("Searched: \(paths.joined(separator: ", "))")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
