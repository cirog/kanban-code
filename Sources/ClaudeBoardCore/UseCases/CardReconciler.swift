import Foundation

/// Pure reconciliation logic — tmux-authoritative association.
///
/// Responsibilities:
/// - Carry forward existing session associations from previous cycle
/// - Build new associations via tmux name → SessionStart hook events
/// - Create discovered cards for truly unmatched sessions
/// - Clear dead tmux links
///
/// NOT responsible for: activity detection (hook does that),
/// column assignment, card-session linking via hooks.
public enum CardReconciler {

    /// A point-in-time snapshot of all discovered external resources.
    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let didScanTmux: Bool
        public let hookEvents: [HookEvent]
        public let existingAssociations: [SessionAssociation]

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            didScanTmux: Bool = false,
            hookEvents: [HookEvent] = [],
            existingAssociations: [SessionAssociation] = []
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.didScanTmux = didScanTmux
            self.hookEvents = hookEvents
            self.existingAssociations = existingAssociations
        }
    }

    /// A session-to-card association to persist.
    public struct SessionAssociation: Sendable {
        public let sessionId: String
        public let cardId: String
        public let matchedBy: String  // "tmux" | "discovered"
        public let path: String?

        public init(sessionId: String, cardId: String, matchedBy: String, path: String?) {
            self.sessionId = sessionId
            self.cardId = cardId
            self.matchedBy = matchedBy
            self.path = path
        }
    }

    /// Result of reconciliation.
    public struct ReconcileResult: Sendable {
        public let links: [Link]
        public let associations: [SessionAssociation]
    }

    /// Reconcile existing cards with discovered resources.
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> ReconcileResult {
        var linksById: [String: Link] = [:]
        for link in existing { linksById[link.id] = link }

        // Step 1: Carry forward ALL existing associations
        var associationsBySessionId: [String: SessionAssociation] = [:]
        var ownedSessionIds: Set<String> = []
        for assoc in snapshot.existingAssociations {
            // Only carry forward if the card still exists
            if linksById[assoc.cardId] != nil {
                associationsBySessionId[assoc.sessionId] = assoc
                ownedSessionIds.insert(assoc.sessionId)
            }
        }

        // Step 2: Build tmux → latest sessionId index from hook events
        // For each tmux name, find the most recent SessionStart
        var tmuxToSessions: [String: [(sessionId: String, path: String?, timestamp: Date)]] = [:]
        for event in snapshot.hookEvents {
            if event.eventName == "SessionStart",
               let tmuxName = event.tmuxSessionName, !tmuxName.isEmpty {
                tmuxToSessions[tmuxName, default: []].append(
                    (sessionId: event.sessionId, path: event.transcriptPath, timestamp: event.timestamp)
                )
            }
        }

        // Step 3: Update associations for managed cards with tmux
        for link in existing {
            guard let tmux = link.tmuxLink else { continue }
            let tmuxName = tmux.sessionName

            if let sessions = tmuxToSessions[tmuxName] {
                // Associate ALL sessions that ran in this tmux to this card
                for sess in sessions {
                    associationsBySessionId[sess.sessionId] = SessionAssociation(
                        sessionId: sess.sessionId, cardId: link.id,
                        matchedBy: "tmux", path: sess.path
                    )
                    ownedSessionIds.insert(sess.sessionId)
                }
            }
        }

        // Step 4: Create discovered cards for unowned sessions
        for session in snapshot.sessions {
            if ownedSessionIds.contains(session.id) { continue }

            ClaudeBoardLog.info("reconciler", "New session \(session.id.prefix(8)) → discovered card")
            let newLink = Link(
                projectPath: session.projectPath,
                column: .done,
                lastActivity: session.modifiedTime,
                source: .discovered,
                slug: session.slug
            )
            linksById[newLink.id] = newLink
            associationsBySessionId[session.id] = SessionAssociation(
                sessionId: session.id, cardId: newLink.id,
                matchedBy: "discovered", path: session.jsonlPath
            )
            ownedSessionIds.insert(session.id)
        }

        // Step 5: Clear dead tmux links
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
            associations: Array(associationsBySessionId.values)
        )
    }
}
