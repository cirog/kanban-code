import Foundation

/// Updates a link's column based on current activity state.
/// Wraps AssignColumn with persistence via CoordinationStore.
public enum UpdateCardColumn {

    /// Update a single link's column assignment.
    public static func update(
        link: inout Link,
        activityState: ActivityState?
    ) {
        let newColumn = AssignColumn.assign(
            link: link,
            activityState: activityState
        )

        // If an archived card becomes actively working, clear the archive flag
        // so it stays in waiting (not done) once work stops.
        if link.manuallyArchived && newColumn == .inProgress {
            link.manuallyArchived = false
        }

        if newColumn != link.column {
            link.column = newColumn
            link.updatedAt = .now
        }
    }
}
