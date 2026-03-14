import Foundation

/// Updates a link's column based on current activity state and worktree existence.
/// Wraps AssignColumn with persistence via CoordinationStore.
public enum UpdateCardColumn {

    /// Update a single link's column assignment.
    public static func update(
        link: inout Link,
        activityState: ActivityState?,
        hasTmux: Bool
    ) {
        let newColumn = AssignColumn.assign(
            link: link,
            activityState: activityState,
            hasTmux: hasTmux
        )

        // If an archived card becomes actively working, clear the archive flag
        // so it stays in waiting (not allSessions) once work stops.
        if link.manuallyArchived && newColumn == .inProgress {
            link.manuallyArchived = false
        }

        if newColumn != link.column {
            link.column = newColumn
            link.updatedAt = .now
        }
    }
}
