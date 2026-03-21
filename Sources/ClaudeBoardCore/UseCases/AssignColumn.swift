import Foundation

/// Determines which Kanban column a link should be in based on its state.
///
/// Priority layers:
///   1. Active work (.activelyWorking) → inProgress
///   2. Live tmux → waiting
///   3. User intent (manual override, archived)
///   4. Activity-driven (any known state → waiting)
///   5. No data (nil) → preserve current column
///   6. Classification (unstarted tasks → backlog)
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil,
        hasLiveTmux: Bool = false
    ) -> ClaudeBoardColumn {
        // --- Priority 1: Active work always inProgress ---
        if activityState == .activelyWorking {
            return .inProgress
        }

        // --- Priority 2: Live tmux → waiting ---
        if hasLiveTmux {
            return .waiting
        }

        // --- Priority 3: User intent ---
        if link.manualOverrides.column {
            return link.column
        }

        if link.manuallyArchived {
            return .done
        }

        // --- Priority 4: Activity-driven (any known state → waiting) ---
        if let activity = activityState {
            switch activity {
            case .activelyWorking:
                return .inProgress // Already handled, exhaustive
            case .needsAttention, .idleWaiting, .ended, .stale:
                return .waiting
            }
        }

        // --- Priority 5: No data (nil) — preserve current column ---
        // On cold start or race conditions, we have no activity data.
        // Don't move cards we can't reason about.

        // Exception: unstarted tasks stay in backlog
        if (link.source == .manual || link.source == .todoist) && link.slug == nil {
            return .backlog
        }

        return link.column
    }
}
