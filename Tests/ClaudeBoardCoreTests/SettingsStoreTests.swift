import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("SettingsStore")
struct SettingsStoreTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-settings-test-\(UUID().uuidString)"
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
        #expect(settings.sessionTimeout.activeThresholdMinutes == 1440)
        #expect(settings.promptTemplate == "")

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
        settings.promptTemplate = "/orchestrate"
        settings.projects = [Project(path: "/test/project", name: "Test")]
        settings.notifications.pushoverToken = "tok_123"

        try await store.write(settings)
        let read = try await store.read()

        #expect(read.promptTemplate == "/orchestrate")
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
        #expect(content.contains("projects"))
        #expect(content.contains("\n"))
    }

    // MARK: - Project CRUD

    @Test("Add project persists")
    func addProject() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        let project = Project(path: "/test/my-project", name: "My Project")
        try await store.addProject(project)

        let settings = try await store.read()
        #expect(settings.projects.count == 1)
        #expect(settings.projects[0].name == "My Project")
        #expect(settings.projects[0].path == "/test/my-project")
    }

    @Test("Add duplicate project throws")
    func addDuplicate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        let project = Project(path: "/test/project")
        try await store.addProject(project)

        do {
            try await store.addProject(project)
            Issue.record("Expected duplicate error")
        } catch {
            #expect(error.localizedDescription.contains("already configured"))
        }
    }

    @Test("Update project persists")
    func updateProject() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        try await store.addProject(Project(path: "/test/project", name: "Original"))

        let updated = Project(path: "/test/project", name: "Updated")
        try await store.updateProject(updated)

        let settings = try await store.read()
        #expect(settings.projects.count == 1)
        #expect(settings.projects[0].name == "Updated")
    }

    @Test("Remove project persists")
    func removeProject() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        try await store.addProject(Project(path: "/test/a"))
        try await store.addProject(Project(path: "/test/b"))

        try await store.removeProject(path: "/test/a")

        let settings = try await store.read()
        #expect(settings.projects.count == 1)
        #expect(settings.projects[0].path == "/test/b")
    }

    @Test("Remove nonexistent project throws")
    func removeNonexistent() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        do {
            try await store.removeProject(path: "/nonexistent")
            Issue.record("Expected not found error")
        } catch {
            #expect(error.localizedDescription.contains("not found"))
        }
    }

    @Test("Project with color round-trips")
    func projectColor() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = SettingsStore(basePath: dir)

        let project = Project(
            path: "/test/project",
            name: "Test",
            color: "#4A90D9"
        )
        try await store.addProject(project)

        let settings = try await store.read()
        #expect(settings.projects[0].color == "#4A90D9")
    }
}
