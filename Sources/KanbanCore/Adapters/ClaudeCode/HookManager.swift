import Foundation

/// Manages Claude Code hook installation for Kanban.
public enum HookManager {

    /// The hook events we need to listen to.
    static let requiredHooks = [
        "Stop", "Notification", "SessionStart", "SessionEnd", "UserPromptSubmit",
    ]

    /// Check if hooks are already installed.
    public static func isInstalled(claudeSettingsPath: String? = nil) -> Bool {
        let path = claudeSettingsPath ?? defaultSettingsPath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        return requiredHooks.allSatisfy { eventName in
            guard let eventHooks = hooks[eventName] as? [[String: Any]] else { return false }
            return eventHooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains("kanban-hook")
            }
        }
    }

    /// Install hooks into Claude's settings, preserving existing hooks.
    public static func install(
        claudeSettingsPath: String? = nil,
        hookScriptPath: String? = nil
    ) throws {
        let settingsPath = claudeSettingsPath ?? defaultSettingsPath()
        let scriptPath = hookScriptPath ?? defaultHookScriptPath()

        // Read existing settings
        var root: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        } else {
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let hookEntry: [String: Any] = [
            "type": "command",
            "command": scriptPath,
        ]

        for eventName in requiredHooks {
            var eventHooks = hooks[eventName] as? [[String: Any]] ?? []

            // Don't add duplicate
            let alreadyInstalled = eventHooks.contains { hook in
                (hook["command"] as? String)?.contains("kanban-hook") == true
            }

            if !alreadyInstalled {
                eventHooks.append(hookEntry)
            }

            hooks[eventName] = eventHooks
        }

        root["hooks"] = hooks

        // Write back
        let fileManager = FileManager.default
        let dir = (settingsPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// Remove Kanban hooks from settings.
    public static func uninstall(claudeSettingsPath: String? = nil) throws {
        let settingsPath = claudeSettingsPath ?? defaultSettingsPath()

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        for eventName in requiredHooks {
            if var eventHooks = hooks[eventName] as? [[String: Any]] {
                eventHooks.removeAll { hook in
                    (hook["command"] as? String)?.contains("kanban-hook") == true
                }
                if eventHooks.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = eventHooks
                }
            }
        }

        root["hooks"] = hooks

        let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: settingsPath))
    }

    private static func defaultSettingsPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    private static func defaultHookScriptPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban/hooks/kanban-hook.sh")
    }
}
