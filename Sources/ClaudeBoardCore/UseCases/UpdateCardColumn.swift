import Foundation

/// Updates a link's column based on PID-based process detection.
/// Wraps AssignColumn with state mutation logic.
public enum UpdateCardColumn {

    /// Update a single link's column assignment.
    public static func update(
        link: inout Link,
        isClaudeRunning: Bool = false,
        lastHookEvent: String? = nil
    ) {
        let newColumn = AssignColumn.assign(
            link: link,
            isClaudeRunning: isClaudeRunning,
            lastHookEvent: lastHookEvent
        )

        // If an archived card becomes actively working, clear the archive flag
        if link.manuallyArchived && newColumn == .inProgress {
            link.manuallyArchived = false
        }

        if newColumn != link.column {
            link.column = newColumn
            link.updatedAt = .now
        }
    }
}
