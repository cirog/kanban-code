import Testing
import Foundation
@testable import KanbanCore

@Suite("SettingsStore")
struct SettingsStoreTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-settings-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Creates default settings on first read")
    func defaultSettings() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        let settings = try await store.read()
        #expect(settings.projects.isEmpty)
        #expect(settings.github.defaultFilter == "assignee:@me is:open")
        #expect(settings.github.pollIntervalSeconds == 60)
        #expect(settings.sessionTimeout.activeThresholdMinutes == 1440)
        #expect(settings.skill == "")

        // File should exist now
        let filePath = (dir as NSString).appendingPathComponent("settings.json")
        #expect(FileManager.default.fileExists(atPath: filePath))
    }

    @Test("Write and read round-trip")
    func roundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        var settings = Settings()
        settings.skill = "/orchestrate"
        settings.projects = [Project(path: "/test/project", name: "Test")]
        settings.notifications.pushoverToken = "tok_123"

        try await store.write(settings)
        let read = try await store.read()

        #expect(read.skill == "/orchestrate")
        #expect(read.projects.count == 1)
        #expect(read.projects[0].name == "Test")
        #expect(read.notifications.pushoverToken == "tok_123")
    }

    @Test("Settings file is human-readable")
    func humanReadable() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        try await store.write(Settings())
        let filePath = (dir as NSString).appendingPathComponent("settings.json")
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("assignee:@me"))
        #expect(content.contains("\n"))
    }

    @Test("Remote settings are optional")
    func remoteOptional() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        let settings = try await store.read()
        #expect(settings.remote == nil)
    }
}
