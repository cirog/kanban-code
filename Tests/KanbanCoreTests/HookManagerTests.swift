import Testing
import Foundation
@testable import KanbanCore

@Suite("HookManager")
struct HookManagerTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-hooks-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Install hooks into empty settings")
    func installEmpty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: "/path/to/kanban-hook.sh")

        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)

        // Verify all hook events are present
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        #expect(hooks["Stop"] != nil)
        #expect(hooks["Notification"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SessionEnd"] != nil)
    }

    @Test("Install preserves existing hooks")
    func installPreservesExisting() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
            "hooks": {
                "Stop": [{"type": "command", "command": "/usr/local/bin/other-hook.sh"}]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: "/path/to/kanban-hook.sh")

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopHooks = hooks["Stop"] as! [[String: Any]]

        // Should have both the existing hook and the new one
        #expect(stopHooks.count == 2)
    }

    @Test("Install is idempotent")
    func installIdempotent() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: "/path/to/kanban-hook.sh")
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: "/path/to/kanban-hook.sh")

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopHooks = hooks["Stop"] as! [[String: Any]]

        // Should NOT have duplicates
        #expect(stopHooks.count == 1)
    }

    @Test("Uninstall removes only kanban hooks")
    func uninstall() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
            "hooks": {
                "Stop": [
                    {"type": "command", "command": "/usr/local/bin/other-hook.sh"},
                    {"type": "command", "command": "/path/to/kanban-hook.sh"}
                ]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.uninstall(claudeSettingsPath: settingsPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopHooks = hooks["Stop"] as! [[String: Any]]

        #expect(stopHooks.count == 1)
        #expect((stopHooks[0]["command"] as! String).contains("other-hook"))
    }

    @Test("isInstalled returns false for missing hooks")
    func notInstalled() {
        let installed = HookManager.isInstalled(claudeSettingsPath: "/nonexistent/path")
        #expect(!installed)
    }

    @Test("Install creates settings file if missing")
    func installCreatesFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("subdir/settings.json")
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: "/path/to/kanban-hook.sh")

        #expect(FileManager.default.fileExists(atPath: settingsPath))
        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)
    }
}
