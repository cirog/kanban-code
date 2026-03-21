import Foundation

/// Pure reconciliation logic — hook-authoritative version.
///
/// Responsibilities:
/// - Match unowned sessions to existing cards by slug
/// - Create discovered cards for truly unmatched sessions
/// - Clear dead tmux links
///
/// NOT responsible for: linking sessions to managed cards (the hook does that),
/// column assignment, activity detection, tmux matching.
public enum CardReconciler {

    /// A point-in-time snapshot of all discovered external resources.
    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let didScanTmux: Bool
        public let ownedSessionIds: Set<String>

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            didScanTmux: Bool = false,
            ownedSessionIds: Set<String> = []
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.didScanTmux = didScanTmux
            self.ownedSessionIds = ownedSessionIds
        }
    }

    /// A new session-to-card association to persist.
    public struct SessionAssociation: Sendable {
        public let sessionId: String
        public let cardId: String
        public let matchedBy: String
        public let path: String?
    }

    /// Result of reconciliation.
    public struct ReconcileResult: Sendable {
        public let links: [Link]
        public let newAssociations: [SessionAssociation]
    }

    /// Reconcile existing cards with discovered resources.
    ///
    /// Three-level association hierarchy:
    /// 1. Already owned? → skip (session is in `ownedSessionIds`)
    /// 2. Slug match → link to existing card that has matching slug
    /// 3. No match → create discovered card
    ///
    /// - Parameters:
    ///   - existing: Current in-memory cards.
    ///   - snapshot: Discovered sessions, tmux sessions, and owned session IDs.
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> ReconcileResult {
        var linksById: [String: Link] = [:]
        for link in existing { linksById[link.id] = link }

        // Build slug → cardId index
        var cardIdBySlug: [String: String] = [:]
        for link in existing {
            if let slug = link.slug, !slug.isEmpty {
                cardIdBySlug[slug] = link.id
            }
        }

        var newAssociations: [SessionAssociation] = []

        // A. Process discovered sessions
        for session in snapshot.sessions {
            // Step 1: Already owned?
            if snapshot.ownedSessionIds.contains(session.id) { continue }

            // Step 2: Slug match
            if let slug = session.slug, !slug.isEmpty,
               let cardId = cardIdBySlug[slug],
               var link = linksById[cardId] {
                if !link.manuallyArchived {
                    link.lastActivity = session.modifiedTime
                    if link.projectPath == nil, let pp = session.projectPath {
                        link.projectPath = pp
                    }
                    linksById[cardId] = link
                }
                newAssociations.append(SessionAssociation(
                    sessionId: session.id, cardId: cardId,
                    matchedBy: "slug", path: session.jsonlPath
                ))
                continue
            }

            // Step 3: No match → create discovered card
            ClaudeBoardLog.info("reconciler", "New session \(session.id.prefix(8)) → discovered card")
            let newLink = Link(
                projectPath: session.projectPath,
                column: .done,
                lastActivity: session.modifiedTime,
                source: .discovered,
                slug: session.slug
            )
            linksById[newLink.id] = newLink
            if let slug = session.slug, !slug.isEmpty {
                cardIdBySlug[slug] = newLink.id
            }
            newAssociations.append(SessionAssociation(
                sessionId: session.id, cardId: newLink.id,
                matchedBy: "discovered", path: session.jsonlPath
            ))
        }

        // B. Clear dead tmux links
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))
        let didScanTmux = snapshot.didScanTmux

        for (id, var link) in linksById {
            guard var tmux = link.tmuxLink, didScanTmux else { continue }
            var changed = false
            let primaryAlive = liveTmuxNames.contains(tmux.sessionName)

            if let extras = tmux.extraSessions {
                let liveExtras = extras.filter { liveTmuxNames.contains($0) }
                tmux.extraSessions = liveExtras.isEmpty ? nil : liveExtras
            }

            if !primaryAlive && tmux.extraSessions == nil {
                link.tmuxLink = nil; changed = true
            } else if !primaryAlive {
                tmux.isPrimaryDead = true; link.tmuxLink = tmux; changed = true
            } else {
                if tmux.isPrimaryDead != nil { tmux.isPrimaryDead = nil }
                if tmux != link.tmuxLink { link.tmuxLink = tmux; changed = true }
            }

            if changed { linksById[id] = link }
        }

        return ReconcileResult(
            links: Array(linksById.values),
            newAssociations: newAssociations
        )
    }
}
