import Foundation

/// Determines which Kanban column a link should be in.
///
/// Rules:
///   1. User intent (manual override, archived) — always respected
///   2. Claude running + UserPromptSubmit → inProgress
///   3. Claude running + anything else → waiting
///   4. Claude NOT running + discovered → done (auto-archive)
///   5. Claude NOT running + managed/todoist → waiting (sticky)
///   6. Unstarted tasks (no session) → backlog
public enum AssignColumn {

    /// Assign a column based on PID-based process detection.
    ///
    /// - Parameters:
    ///   - link: The card
    ///   - isClaudeRunning: Whether the Claude process (PID) is alive for this card's session
    ///   - lastHookEvent: The most recent hook event name (e.g. "UserPromptSubmit", "Stop")
    public static func assign(
        link: Link,
        isClaudeRunning: Bool = false,
        lastHookEvent: String? = nil
    ) -> ClaudeBoardColumn {
        // --- Claude actively working overrides everything ---
        if isClaudeRunning && lastHookEvent == "UserPromptSubmit" {
            return .inProgress
        }

        // --- User intent ---
        if link.manualOverrides.column {
            return link.column
        }

        if link.manuallyArchived {
            return .done
        }

        // --- Claude IS running (but not actively working) ---
        if isClaudeRunning {
            return .waiting
        }

        // --- Claude NOT running ---
        if link.source == .discovered {
            return .done
        }

        // Managed/todoist: sticky in waiting until manual archive
        // Exception: unstarted tasks (no session ever) stay in backlog
        if (link.source == .manual || link.source == .todoist) && link.slug == nil && lastHookEvent == nil {
            return .backlog
        }

        return .waiting
    }
}
