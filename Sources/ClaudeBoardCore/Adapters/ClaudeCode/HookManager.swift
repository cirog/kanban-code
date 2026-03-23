import Foundation

/// Manages hook installation for Claude Code.
///
/// Claude Code uses hook configuration format:
/// `settings.json` → `hooks` → `{ EventName: [{ matcher, hooks: [{ type, command }] }] }`
///
/// The hook script (`~/.claude-board/hook.sh`) receives
/// `session_id`, `hook_event_name`, and `transcript_path` via stdin JSON.
public enum HookManager {

    /// Hook events needed per assistant.
    public static func requiredHooks(for assistant: CodingAssistant) -> [String] {
        switch assistant {
        case .claude:
            ["Stop", "Notification", "SessionStart", "SessionEnd", "UserPromptSubmit"]
        }
    }

    /// Claude Code's required hooks (backward compat).
    static let requiredHooks = requiredHooks(for: .claude)

    /// Normalize event names to the canonical names the orchestrator understands.
    public static func normalizeEventName(_ name: String) -> String {
        name
    }

    // MARK: - Check

    /// Check if hooks are already installed for the given assistant.
    public static func isInstalled(for assistant: CodingAssistant, settingsPath: String? = nil) -> Bool {
        let path = settingsPath ?? defaultSettingsPath(for: assistant)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        return requiredHooks(for: assistant).allSatisfy { eventName in
            guard let groups = hooks[eventName] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let hookEntries = group["hooks"] as? [[String: Any]] else { return false }
                return hookEntries.contains { entry in
                    (entry["command"] as? String)?.contains(".claude-board/hook.sh") == true
                }
            }
        }
    }

    /// Backward-compatible: check Claude hooks only.
    public static func isInstalled(claudeSettingsPath: String? = nil) -> Bool {
        isInstalled(for: .claude, settingsPath: claudeSettingsPath)
    }

    // MARK: - Install

    /// Install hooks for the given assistant.
    public static func install(
        for assistant: CodingAssistant,
        settingsPath: String? = nil,
        hookScriptPath: String? = nil
    ) throws {
        let resolvedSettingsPath = settingsPath ?? defaultSettingsPath(for: assistant)
        let scriptPath = hookScriptPath ?? defaultHookScriptPath()

        // Deploy the hook script to disk
        try deployHookScript(to: scriptPath)

        // Read existing settings
        var root: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: resolvedSettingsPath)),
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

        for eventName in requiredHooks(for: assistant) {
            var groups = hooks[eventName] as? [[String: Any]] ?? []

            // Check if .claude-board/hook.sh already exists in any group
            let alreadyInstalled = groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String)?.contains(".claude-board/hook.sh") == true }
            }

            if !alreadyInstalled {
                if groups.isEmpty {
                    groups.append(["matcher": "", "hooks": [hookEntry]])
                } else {
                    var firstGroup = groups[0]
                    var entries = firstGroup["hooks"] as? [[String: Any]] ?? []
                    entries.append(hookEntry)
                    firstGroup["hooks"] = entries
                    groups[0] = firstGroup
                }
            }

            hooks[eventName] = groups
        }

        root["hooks"] = hooks

        // Write back
        let fileManager = FileManager.default
        let dir = (resolvedSettingsPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: resolvedSettingsPath))
    }

    /// Backward-compatible: install Claude hooks only.
    public static func install(
        claudeSettingsPath: String? = nil,
        hookScriptPath: String? = nil
    ) throws {
        try install(for: .claude, settingsPath: claudeSettingsPath, hookScriptPath: hookScriptPath)
    }

    // MARK: - Private

    private static func deployHookScript(to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        try hookScriptContent.write(toFile: path, atomically: true, encoding: .utf8)

        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }

    private static let hookScriptContent = """
    #!/usr/bin/env bash
    # ClaudeBoard hook handler for Claude Code.
    # Receives JSON on stdin from hooks, appends a timestamped
    # event line to ~/.claude-board/hook-events.jsonl.

    set -euo pipefail

    EVENTS_DIR="${HOME}/.claude-board"
    EVENTS_FILE="${EVENTS_DIR}/hook-events.jsonl"

    # Ensure directory exists
    mkdir -p "$EVENTS_DIR"

    # Read the JSON payload from stdin
    input=$(cat)

    # Extract fields using lightweight parsing (no jq dependency)
    session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    transcript=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Fallback: try sessionId (different hook formats)
    if [ -z "$session_id" ]; then
        session_id=$(echo "$input" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # Skip if we couldn't extract a session ID
    [ -z "$session_id" ] && exit 0

    # Get current timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Append event line
    printf '{"sessionId":"%s","event":"%s","timestamp":"%s","transcriptPath":"%s"}\\n' \\
        "$session_id" "$hook_event" "$timestamp" "$transcript" >> "$EVENTS_FILE"
    """

    /// Settings file path per assistant.
    public static func defaultSettingsPath(for assistant: CodingAssistant) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("\(assistant.configDirName)/settings.json")
    }

    private static func defaultSettingsPath() -> String {
        defaultSettingsPath(for: .claude)
    }

    private static func defaultHookScriptPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude-board/hook.sh")
    }
}
