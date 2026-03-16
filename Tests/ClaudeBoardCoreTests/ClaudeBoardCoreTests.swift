import Testing
@testable import ClaudeBoardCore

@Suite("ClaudeBoardCore")
struct ClaudeBoardCoreTests {
    @Test("Version is set")
    func versionIsSet() {
        #expect(ClaudeBoardCore.version == "0.1.0")
    }
}
