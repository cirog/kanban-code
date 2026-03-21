import Foundation

/// Pure reconciliation logic — hook-authoritative version.
///
/// Responsibilities:
/// - Update lastActivity/metadata for cards that already have a session link
/// - Create discovered cards for truly unmatched sessions
/// - Clear dead tmux links
///
/// NOT responsible for: linking sessions to managed cards (the hook does that),
/// column assignment, activity detection.
public enum CardReconciler {

    /// A point-in-time snapshot of all discovered external resources.
    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let didScanTmux: Bool

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            didScanTmux: Bool = false
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.didScanTmux = didScanTmux
        }
    }

    /// Result of reconciliation.
    public struct ReconcileResult: Sendable {
        public let links: [Link]
    }

    /// Reconcile existing cards with discovered resources.
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> ReconcileResult {
        var linksById: [String: Link] = [:]
        for link in existing {
            linksById[link.id] = link
        }

        // Build sessionId → cardId index for O(1) lookup
        var cardIdBySessionId: [String: String] = [:]
        for link in existing {
            if let sid = link.sessionLink?.sessionId {
                cardIdBySessionId[sid] = link.id
            }
        }

        // A. Process discovered sessions
        for session in snapshot.sessions {
            if let cardId = cardIdBySessionId[session.id],
               var link = linksById[cardId] {
                // Session already linked to a card — update metadata
                if link.manuallyArchived {
                    continue // Archived cards stay archived
                }
                link.sessionLink?.sessionPath = session.jsonlPath
                if let slug = session.slug {
                    link.sessionLink?.slug = slug
                }
                link.lastActivity = session.modifiedTime
                if link.projectPath == nil, let pp = session.projectPath {
                    link.projectPath = pp
                }
                linksById[cardId] = link
            } else {
                // Truly unmatched session — create discovered card
                ClaudeBoardLog.info("reconciler", "New session \(session.id.prefix(8)) → discovered card")
                let newLink = Link(
                    projectPath: session.projectPath,
                    column: .done,
                    lastActivity: session.modifiedTime,
                    source: .discovered,
                    sessionLink: SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath,
                        slug: session.slug
                    )
                )
                linksById[newLink.id] = newLink
                cardIdBySessionId[session.id] = newLink.id
            }
        }

        // B. Clear dead tmux links
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))
        let didScanTmux = snapshot.didScanTmux

        for (id, var link) in linksById {
            guard var tmux = link.tmuxLink,
                  !link.manualOverrides.tmuxSession,
                  didScanTmux else { continue }

            var changed = false
            let primaryAlive = liveTmuxNames.contains(tmux.sessionName)

            // Filter dead extra sessions
            if let extras = tmux.extraSessions {
                let liveExtras = extras.filter { liveTmuxNames.contains($0) }
                tmux.extraSessions = liveExtras.isEmpty ? nil : liveExtras
            }

            if !primaryAlive && tmux.extraSessions == nil {
                link.tmuxLink = nil
                changed = true
            } else if !primaryAlive {
                tmux.isPrimaryDead = true
                link.tmuxLink = tmux
                changed = true
            } else {
                if tmux.isPrimaryDead != nil {
                    tmux.isPrimaryDead = nil
                }
                if tmux != link.tmuxLink {
                    link.tmuxLink = tmux
                    changed = true
                }
            }

            if changed {
                linksById[id] = link
            }
        }

        return ReconcileResult(links: Array(linksById.values))
    }
}
