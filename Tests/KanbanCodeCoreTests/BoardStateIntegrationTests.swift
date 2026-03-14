import Testing
import Foundation
@testable import KanbanCodeCore

/// Mock discovery that returns configurable sessions.
final class MockSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    var sessions: [Session] = []

    func discoverSessions() async throws -> [Session] {
        sessions
    }

    func discoverNewOrModified(since: Date) async throws -> [Session] {
        sessions
    }
}

@Suite("BoardState Integration")
struct BoardStateIntegrationTests {

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-board-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Card ID stability

    @Test("Card IDs are stable across refreshes")
    func cardIdStability() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "session-1", name: "First", messageCount: 5, modifiedTime: .now),
            Session(id: "session-2", name: "Second", messageCount: 3, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let firstIds = Set(state.cards.map(\.id))
        #expect(firstIds.count == 2)

        // Refresh again — IDs should be the same
        await state.refresh()
        let secondIds = Set(state.cards.map(\.id))
        #expect(firstIds == secondIds)
    }

    @Test("Card IDs use link.id (not sessionId)")
    func cardIdIsLinkId() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "my-session-uuid", name: "Test", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        #expect(state.cards.count == 1)
        // Card ID is the link's UUID, not the session's UUID
        let card = state.cards[0]
        #expect(card.id == card.link.id)
        #expect(card.link.sessionLink?.sessionId == "my-session-uuid")
    }

    @Test("selectedCardId survives refresh when card still exists")
    func selectedCardSurvivesRefresh() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", name: "Session", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id
        state.selectedCardId = cardId

        await state.refresh()
        #expect(state.selectedCardId == cardId)
    }

    @Test("selectedCardId cleared when card disappears from both discovery and store")
    func selectedCardClearedOnDisappear() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", name: "Session", messageCount: 1, modifiedTime: .now),
            Session(id: "s2", name: "Other", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id
        state.selectedCardId = cardId

        // Session disappears from discovery AND we clear it from the store
        discovery.sessions = [
            Session(id: "s2", name: "Other", messageCount: 1, modifiedTime: .now),
        ]
        try await store.removeLink(id: cardId)
        await state.refresh()
        #expect(state.selectedCardId == nil)
    }

    @Test("Persisted links survive when session disappears from discovery only")
    func persistedLinksSurviveDiscoveryGap() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", name: "Session", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id
        state.selectedCardId = cardId

        // Session temporarily disappears from discovery (e.g. file locked)
        // but still exists in the coordination store
        discovery.sessions = []
        await state.refresh()

        // Card still exists because it's persisted in the store
        #expect(state.cards.contains(where: { $0.id == cardId }))
        #expect(state.selectedCardId == cardId)
    }

    // MARK: - Rename persistence

    @Test("Rename persists through refresh cycle")
    func renamePersistsThroughRefresh() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", name: "Original Name", messageCount: 5, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        // First refresh to populate
        await state.refresh()
        #expect(state.cards.count == 1)

        // Find card by sessionId to get its actual link.id
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id

        // Rename the card
        state.renameCard(cardId: cardId, name: "My Custom Name")

        // Verify in-memory update
        #expect(state.cards.first(where: { $0.id == cardId })?.displayTitle == "My Custom Name")

        // Wait for the async persist Task to complete
        try await Task.sleep(for: .milliseconds(100))

        // Refresh — this re-reads from CoordinationStore + discovery
        await state.refresh()

        // Name should survive
        let card = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })
        #expect(card?.link.name == "My Custom Name")
        #expect(card?.link.manualOverrides.name == true)
        #expect(card?.displayTitle == "My Custom Name")
    }

    @Test("Rename written to CoordinationStore")
    func renameWrittenToStore() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id
        state.renameCard(cardId: cardId, name: "Renamed")
        try await Task.sleep(for: .milliseconds(100))

        // Read directly from store
        let link = try await store.linkForSession("s1")
        #expect(link?.name == "Renamed")
        #expect(link?.manualOverrides.name == true)
    }

    // MARK: - Move persistence

    @Test("moveCard persists through refresh cycle")
    func moveCardPersistsThroughRefresh() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id
        state.moveCard(cardId: cardId, to: .inProgress)
        try await Task.sleep(for: .milliseconds(100))

        // Refresh
        await state.refresh()

        let card = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })
        #expect(card?.link.column == .inProgress)
        #expect(card?.link.manualOverrides.column == true)
    }

    @Test("reorderCard persists through refresh cycle")
    func reorderCardPersistsThroughRefresh() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        let store = CoordinationStore(basePath: dir)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.writeLinks([
            Link(id: "card_1", name: "First", projectPath: "/test/project", column: .backlog, createdAt: timestamp, updatedAt: timestamp, source: .manual, sortOrder: 0),
            Link(id: "card_2", name: "Second", projectPath: "/test/project", column: .backlog, createdAt: timestamp, updatedAt: timestamp, source: .manual, sortOrder: 1),
            Link(id: "card_3", name: "Third", projectPath: "/test/project", column: .backlog, createdAt: timestamp, updatedAt: timestamp, source: .manual, sortOrder: 2),
        ])
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        #expect(state.cards(in: .backlog).map(\.id) == ["card_1", "card_2", "card_3"])

        state.reorderCard(cardId: "card_3", targetCardId: "card_1", above: true)
        try await Task.sleep(for: .milliseconds(100))

        await state.refresh()

        #expect(state.cards(in: .backlog).map(\.id) == ["card_3", "card_1", "card_2"])

        let links = try await store.readLinks()
        let persisted = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        #expect(persisted["card_3"]?.sortOrder == 0)
        #expect(persisted["card_1"]?.sortOrder == 1)
        #expect(persisted["card_2"]?.sortOrder == 2)
    }

    // MARK: - Refresh persists merged links

    @Test("Refresh writes all links to CoordinationStore")
    func refreshPersistsLinks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", messageCount: 1, modifiedTime: .now),
            Session(id: "s2", messageCount: 2, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        // Before refresh, store should be empty
        let before = try await store.readLinks()
        #expect(before.isEmpty)

        await state.refresh()

        // After refresh, store should have links
        let after = try await store.readLinks()
        #expect(after.count == 2)
        let sessionIds = Set(after.map(\.sessionId))
        #expect(sessionIds.contains("s1"))
        #expect(sessionIds.contains("s2"))
    }

    // MARK: - Archive persistence

    @Test("archiveCard sets manuallyArchived and persists")
    func archiveCardPersists() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id
        state.archiveCard(cardId: cardId)

        // In-memory: card should be done and manuallyArchived
        let card = state.cards.first(where: { $0.id == cardId })
        #expect(card?.link.column == .done)
        #expect(card?.link.manuallyArchived == true)

        // Wait for async persist
        try await Task.sleep(for: .milliseconds(100))

        // Persists through refresh
        await state.refresh()
        let refreshed = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })
        #expect(refreshed?.link.manuallyArchived == true)
        #expect(refreshed?.link.column == .done)
    }

    // MARK: - Project filtering

    @Test("Filters cards by selected project")
    func filtersByProject() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", projectPath: "/projects/langwatch", messageCount: 1, modifiedTime: .now),
            Session(id: "s2", projectPath: "/projects/scenario", messageCount: 1, modifiedTime: .now),
            Session(id: "s3", projectPath: "/projects/langwatch", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        #expect(state.filteredCards.count == 3)

        // Filter to langwatch
        state.selectedProjectPath = "/projects/langwatch"
        #expect(state.filteredCards.count == 2)
        #expect(state.filteredCards.allSatisfy {
            ($0.link.projectPath ?? $0.session?.projectPath) == "/projects/langwatch"
        })

        // Filter to scenario
        state.selectedProjectPath = "/projects/scenario"
        #expect(state.filteredCards.count == 1)

        // Back to global
        state.selectedProjectPath = nil
        #expect(state.filteredCards.count == 3)
    }

    @Test("Project filtering includes subdirectories")
    func filterIncludesSubdirs() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", projectPath: "/projects/saas/langwatch", messageCount: 1, modifiedTime: .now),
            Session(id: "s2", projectPath: "/projects/saas", messageCount: 1, modifiedTime: .now),
            Session(id: "s3", projectPath: "/projects/other", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        state.selectedProjectPath = "/projects/saas"
        #expect(state.filteredCards.count == 2)
    }

    @Test("Cards without project path excluded from project view")
    func noProjectPathExcluded() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", projectPath: "/projects/foo", messageCount: 1, modifiedTime: .now),
            Session(id: "s2", messageCount: 1, modifiedTime: .now), // no projectPath
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        state.selectedProjectPath = "/projects/foo"
        #expect(state.filteredCards.count == 1)
        #expect(state.filteredCards[0].link.sessionLink?.sessionId == "s1")
    }

    @Test("New sessions merge with existing persisted links")
    func newSessionsMergeWithExisting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let s1CardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id
        state.renameCard(cardId: s1CardId, name: "Custom")
        try await Task.sleep(for: .milliseconds(100))

        // Add a new session
        discovery.sessions.append(
            Session(id: "s2", messageCount: 1, modifiedTime: .now)
        )
        await state.refresh()

        // Both should exist, s1 should keep its name
        #expect(state.cards.count == 2)
        let s1 = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })
        #expect(s1?.link.name == "Custom")
    }
    // MARK: - Launch/Resume immediate feedback

    @Test("updateCardForLaunch sets tmuxLink and column immediately")
    func updateCardForLaunchImmediate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id

        // Simulate launch: update card in-memory
        state.updateCardForLaunch(cardId: cardId, tmuxName: "claude-abc12345")

        // Verify immediate in-memory state
        let card = state.cards.first(where: { $0.id == cardId })
        #expect(card?.link.tmuxLink?.sessionName == "claude-abc12345")
        #expect(card?.link.column == .inProgress)
    }

    @Test("updateCardForLaunch persists column to disk")
    func updateCardForLaunchPersistsColumn() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        discovery.sessions = [
            Session(id: "s1", messageCount: 1, modifiedTime: .now),
        ]
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        let cardId = state.cards.first(where: { $0.link.sessionLink?.sessionId == "s1" })!.id

        // Simulate launch: update in-memory + persist
        state.updateCardForLaunch(cardId: cardId, tmuxName: "claude-abc12345")
        try await store.updateLink(id: cardId) { link in
            link.tmuxLink = TmuxLink(sessionName: "claude-abc12345")
            link.column = .inProgress
        }

        // Verify disk persistence
        let links = try await store.readLinks()
        let persisted = links.first(where: { $0.id == cardId })
        #expect(persisted?.tmuxLink?.sessionName == "claude-abc12345")
        #expect(persisted?.column == .inProgress)
    }

    @Test("addCard makes card visible immediately")
    func addCardImmediate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = MockSessionDiscovery()
        let store = CoordinationStore(basePath: dir)
        let state = BoardState(discovery: discovery, coordinationStore: store)

        await state.refresh()
        #expect(state.cards.isEmpty)

        // Add a manual task card
        let link = Link(
            name: "Fix auth bug",
            projectPath: "/projects/test",
            source: .manual,
            promptBody: "Fix the auth bug"
        )
        state.addCard(link: link)

        // Should be visible immediately
        #expect(state.cards.count == 1)
        #expect(state.cards[0].link.name == "Fix auth bug")
        #expect(state.cards[0].link.source == .manual)
    }
}

@Suite("Deep Search")
struct DeepSearchIntegrationTests {

    let store = ClaudeCodeSessionStore()

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-search-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // Search tests removed (search feature stripped)
}

@Suite("SessionIndexReader Update")
struct SessionIndexUpdateTests {

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-index-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("updateSummary updates session in index file")
    func updateSummary() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create a project directory with sessions-index.json
        let projectDir = (dir as NSString).appendingPathComponent("-test-project")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        let indexPath = (projectDir as NSString).appendingPathComponent("sessions-index.json")
        let indexContent: [String: Any] = [
            "version": 1,
            "entries": [
                ["sessionId": "abc-123", "summary": "Old Name", "messageCount": 5] as [String: Any],
                ["sessionId": "def-456", "summary": "Other Session", "messageCount": 3] as [String: Any],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: indexContent, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: indexPath))

        // Update summary
        try SessionIndexReader.updateSummary(
            sessionId: "abc-123",
            summary: "My Custom Name",
            claudeDir: dir
        )

        // Verify
        let updated = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let root = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        let entries = root["entries"] as! [[String: Any]]
        let target = entries.first { $0["sessionId"] as? String == "abc-123" }
        #expect(target?["summary"] as? String == "My Custom Name")

        // Other session untouched
        let other = entries.first { $0["sessionId"] as? String == "def-456" }
        #expect(other?["summary"] as? String == "Other Session")
    }

    @Test("updateSummary handles missing session gracefully")
    func updateSummaryMissing() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // No index files — should not throw
        try SessionIndexReader.updateSummary(
            sessionId: "nonexistent",
            summary: "Name",
            claudeDir: dir
        )
    }
}
