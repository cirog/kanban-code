import Foundation

/// Determines which Kanban column a link should be in based on its state.
///
/// Priority layers:
///   1. Live process (activelyWorking or live tmux) — always on board
///   2. User intent (manual override, archived) — respected when no process
///   3. Classification (task source, default) — fallback
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil,
        hasLiveTmux: Bool = false
    ) -> ClaudeBoardColumn {
        // --- Priority 1: Live process always on board ---

        // Actively working always shows in progress — pierces everything.
        if activityState == .activelyWorking {
            return .inProgress
        }

        // Live tmux = process on machine → keep visible in waiting.
        if hasLiveTmux {
            return .waiting
        }

        // --- Priority 2: No live process — user intent ---

        if link.manualOverrides.column {
            return link.column
        }

        if link.manuallyArchived {
            return .done
        }

        // --- Priority 3: No live process — classification ---

        // Task without a session → backlog (not started yet)
        if (link.source == .manual || link.source == .todoist) && link.sessionLink == nil {
            return .backlog
        }

        // Default: done
        return .done
    }
}
