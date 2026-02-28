import SwiftUI
import KanbanCore

struct ContentView: View {
    @State private var boardState: BoardState
    @State private var showSearch = false

    init() {
        let discovery = ClaudeCodeSessionDiscovery()
        let coordination = CoordinationStore()
        _boardState = State(initialValue: BoardState(discovery: discovery, coordinationStore: coordination))
    }

    var body: some View {
        ZStack {
            BoardView(state: boardState)

            if showSearch {
                // Blurred background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showSearch = false }

                SearchOverlay(
                    isPresented: $showSearch,
                    cards: boardState.cards,
                    onSelectCard: { card in
                        boardState.selectedCardId = card.id
                    }
                )
                .padding(40)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showSearch)
        .task {
            await boardState.refresh()
        }
        .task(id: "refresh-timer") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await boardState.refresh()
            }
        }
        .background {
            // Hidden button to capture Cmd+K
            Button("") { showSearch.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }
}
