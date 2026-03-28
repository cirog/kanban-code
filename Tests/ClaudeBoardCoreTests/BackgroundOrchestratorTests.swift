import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("BackgroundOrchestrator")
struct BackgroundOrchestratorTests {

    @Test("appIsActive defaults to true")
    func appIsActiveDefaultsToTrue() {
        let orch = BackgroundOrchestrator(
            discovery: StubDiscovery(),
            coordinationStore: CoordinationStore(basePath: NSTemporaryDirectory() + "orch-test-\(UUID())"),
            activityDetector: StubActivityDetector()
        )
        #expect(orch.appIsActive == true)
    }
}

// MARK: - Stubs

private struct StubDiscovery: SessionDiscovery {
    func discoverSessions() async throws -> [Session] { [] }
    func discoverNewOrModified(since: Date) async throws -> [Session] { [] }
}

private final class StubActivityDetector: ActivityDetector, @unchecked Sendable {
    func handleHookEvent(_ event: HookEvent) async {}
    func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] { [:] }
    func activityState(for sessionId: String) async -> ActivityState { .ended }
    func resolvePendingStops() async -> [String] { [] }
}
