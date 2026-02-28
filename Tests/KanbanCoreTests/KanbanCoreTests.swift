import Testing
@testable import KanbanCore

@Suite("KanbanCore")
struct KanbanCoreTests {
    @Test("Version is set")
    func versionIsSet() {
        #expect(KanbanCore.version == "0.1.0")
    }
}
