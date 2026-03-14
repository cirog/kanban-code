import Foundation

/// Determines which Kanban column a link should be in based on its state.
/// Respects manual overrides — if the user dragged a card to a column, keep it there.
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil,
        hasTmux: Bool = false
    ) -> KanbanCodeColumn {
        // Manual backlog override is sticky — user explicitly parked this card.
        // Only resumeCard/launchCard (which clear manualOverrides.column) can move it out.
        // This check must run BEFORE .activelyWorking to prevent activity from
        // corrupting the backlog override (which would then be cleared by reconciliation).
        if link.manualOverrides.column && link.column == .backlog {
            return .backlog
        }

        // Actively working always shows in progress — even if manually archived.
        // If the user talks to an archived session, it should come back to life.
        if activityState == .activelyWorking {
            return .inProgress
        }

        // Archive wins over everything else
        if link.manuallyArchived {
            return .allSessions
        }

        // Manual drag override (non-terminal)
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
            case .ended:
                break // fall through to recency check below
            case .stale:
                break // No hook data: fall through to recency check below
            }
        }

        // Manual task without a session yet → backlog
        // BUT if tmuxLink is set and NOT shell-only, it's being actively launched → stay in progress
        if link.source == .manual && link.sessionLink == nil {
            if link.tmuxLink != nil && link.tmuxLink?.isShellOnly != true {
                KanbanCodeLog.info("assign-column", "Manual card \(link.id.prefix(12)) has tmuxLink → inProgress (launching)")
                return .inProgress
            }
            return .backlog
        }

        // Live tmux session → at least waiting (never allSessions)
        if hasTmux {
            return .waiting
        }

        // Recently active (within 24h) → waiting
        if let lastActivity = link.lastActivity {
            let hoursSinceActivity = Date.now.timeIntervalSince(lastActivity) / 3600
            if hoursSinceActivity < 24 {
                return .waiting
            }
        }

        // Default: allSessions
        return .allSessions
    }
}
