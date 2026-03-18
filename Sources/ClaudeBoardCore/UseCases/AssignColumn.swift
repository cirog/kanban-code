import Foundation

/// Determines which Kanban column a link should be in based on its state.
/// Respects manual overrides — if the user dragged a card to a column, keep it there.
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil
    ) -> ClaudeBoardColumn {
        // Actively working always shows in progress — even if manually in backlog or archived.
        if activityState == .activelyWorking {
            return .inProgress
        }

        // Manual backlog override is sticky — user explicitly parked this card.
        // Only resumeCard/launchCard (which clear manualOverrides.column) or
        // activelyWorking (checked above) can move it out.
        if link.manualOverrides.column && link.column == .backlog {
            return .backlog
        }

        // Archive wins over everything else
        if link.manuallyArchived {
            return .done
        }

        // Manual drag override
        if link.manualOverrides.column {
            return link.column
        }

        // Activity-based assignment
        if let state = activityState {
            switch state {
            case .activelyWorking:
                return .inProgress // Already handled above, but keep for exhaustive switch
            case .needsAttention:
                return .waiting
            case .idleWaiting:
                return .waiting
            case .ended, .stale:
                break // fall through to recency check below
            }
        }

        // Summary sessions → done
        if let prompt = link.promptBody, prompt.hasPrefix("[CB-SUMMARY]") {
            return .done
        }

        // Manual task without a session yet → backlog
        // BUT if tmuxLink is set and NOT shell-only, it's being actively launched → stay in progress
        if link.source == .manual && link.sessionLink == nil {
            if link.tmuxLink != nil && link.tmuxLink?.isShellOnly != true {
                ClaudeBoardLog.info("assign-column", "Manual card \(link.id.prefix(12)) has tmuxLink → inProgress (launching)")
                return .inProgress
            }
            return .backlog
        }

        // Todoist task without a session → backlog
        if link.source == .todoist && link.sessionLink == nil {
            return .backlog
        }

        // Scheduled tasks without a terminal are completed runs → done
        if let prompt = link.promptBody, prompt.contains("<scheduled-task"), link.tmuxLink == nil {
            return .done
        }

        // Recently active (within 24h) → waiting
        if let lastActivity = link.lastActivity {
            let hoursSinceActivity = Date.now.timeIntervalSince(lastActivity) / 3600
            if hoursSinceActivity < 24 {
                return .waiting
            }
        }

        // Default: done
        return .done
    }
}
