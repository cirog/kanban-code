import Foundation

/// Pure reconciliation logic: matches discovered resources to existing cards,
/// preventing duplicate card creation.
///
/// Responsibilities:
/// - Match discovered sessions to existing cards (by sessionId → tmux name)
/// - Create new cards for truly unmatched sessions
/// - Clear dead tmux links
///
/// NOT responsible for: column assignment, activity detection.
public enum CardReconciler {

    /// A point-in-time snapshot of all discovered external resources.
    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let didScanTmux: Bool                    // true if tmux was queried (even if 0 results)

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
    /// Returns the merged list of links and IDs of cards that were merged away (slug dedup).
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> ReconcileResult {
        var linksById: [String: Link] = [:]
        for link in existing {
            linksById[link.id] = link
        }

        // Build reverse indexes for matching
        var cardIdBySessionId: [String: String] = [:]
        var cardIdByTmuxName: [String: String] = [:]
        var cardIdBySlug: [String: String] = [:]

        for link in existing {
            if let sid = link.sessionLink?.sessionId {
                cardIdBySessionId[sid] = link.id
            }
            if let slug = link.sessionLink?.slug, !slug.isEmpty {
                cardIdBySlug[slug] = link.id
            }
            if let tmux = link.tmuxLink {
                for name in tmux.allSessionNames {
                    cardIdByTmuxName[name] = link.id
                }
            }
        }

        // Track which sessions we've matched so we can detect new ones
        var matchedSessionIds: Set<String> = []
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))

        // A. Match sessions to existing cards
        for session in snapshot.sessions {
            let cardId = findCardForSession(
                session: session,
                cardIdBySessionId: cardIdBySessionId,
                cardIdBySlug: cardIdBySlug,
                cardIdByTmuxName: cardIdByTmuxName,
                linksById: linksById
            )

            if let cardId, var link = linksById[cardId] {
                // Archived cards stay archived — just mark matched to prevent duplicates
                if link.manuallyArchived {
                    matchedSessionIds.insert(session.id)
                    continue
                }
                // Update existing card with session data
                if link.sessionLink == nil {
                    ClaudeBoardLog.info("reconciler", "Linking session \(session.id.prefix(8)) to existing card \(cardId.prefix(12))")
                    link.sessionLink = SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath,
                        slug: session.slug
                    )
                    cardIdBySessionId[session.id] = link.id
                } else if link.sessionLink?.sessionId != session.id {
                    // Slug match with different sessionId → chain sessions
                    ClaudeBoardLog.info("reconciler", "Chaining session \(session.id.prefix(8)) to card \(cardId.prefix(12)) via slug")
                    var pathSet = Set(link.sessionLink?.previousSessionPaths ?? [])
                    if let oldPath = link.sessionLink?.sessionPath {
                        pathSet.insert(oldPath)
                    }
                    // Don't include the new session's own path in previous
                    if let newPath = session.jsonlPath {
                        pathSet.remove(newPath)
                    }
                    let dedupedPaths = pathSet.sorted()
                    link.sessionLink = SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath,
                        slug: session.slug,
                        previousSessionPaths: dedupedPaths.isEmpty ? nil : dedupedPaths
                    )
                    cardIdBySessionId[session.id] = link.id
                } else {
                    // Same sessionId — update path and slug
                    link.sessionLink?.sessionPath = session.jsonlPath
                    if let slug = session.slug {
                        link.sessionLink?.slug = slug
                    }
                }
                link.lastActivity = session.modifiedTime
                if link.projectPath == nil, let pp = session.projectPath {
                    link.projectPath = pp
                }
                linksById[cardId] = link
                matchedSessionIds.insert(session.id)
            } else {
                ClaudeBoardLog.info("reconciler", "New session \(session.id.prefix(8)) → new card")
                // Truly new session — create discovered card
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
                if let slug = session.slug {
                    cardIdBySlug[slug] = newLink.id
                }
                matchedSessionIds.insert(session.id)
            }
        }

        // B. Clear dead tmux links
        let didScanTmux = snapshot.didScanTmux

        for (id, var link) in linksById {
            var changed = false

            // Clear dead tmux links (tmux session no longer exists)
            // Only clear if we actually scanned tmux (avoid clearing when snapshot has no tmux data)
            // Skip cards mid-launch — the tmux session may not be visible yet
            if var tmux = link.tmuxLink, link.isLaunching != true, !link.manualOverrides.tmuxSession, didScanTmux {
                let primaryAlive = liveTmuxNames.contains(tmux.sessionName)

                // Filter dead extra sessions
                if let extras = tmux.extraSessions {
                    let liveExtras = extras.filter { liveTmuxNames.contains($0) }
                    tmux.extraSessions = liveExtras.isEmpty ? nil : liveExtras
                }

                if !primaryAlive && tmux.extraSessions == nil {
                    // Both primary and all extras dead
                    link.tmuxLink = nil
                    changed = true
                } else if !primaryAlive {
                    // Primary dead but extras alive — mark primary dead
                    tmux.isPrimaryDead = true
                    link.tmuxLink = tmux
                    changed = true
                } else {
                    // Primary alive — ensure isPrimaryDead is cleared
                    if tmux.isPrimaryDead != nil {
                        tmux.isPrimaryDead = nil
                    }
                    if tmux != link.tmuxLink {
                        link.tmuxLink = tmux
                        changed = true
                    }
                }
            }

            if changed {
                linksById[id] = link
            }
        }

        return ReconcileResult(links: Array(linksById.values))
    }

    // MARK: - Private

    /// Find an existing card that should own this session.
    /// Match priority: exact sessionId → project path + tmux (no session) → promptBody → slug.
    private static func findCardForSession(
        session: Session,
        cardIdBySessionId: [String: String],
        cardIdBySlug: [String: String],
        cardIdByTmuxName: [String: String],
        linksById: [String: Link]
    ) -> String? {
        // 1. Exact match by sessionId
        if let cardId = cardIdBySessionId[session.id] {
            ClaudeBoardLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by sessionId → card=\(cardId.prefix(12))")
            return cardId
        }

        // 2. Match by project path + tmux (card has tmuxLink, same project, no sessionLink yet)
        //    Skip cards mid-launch — the launch flow will set sessionLink via launchCompleted
        if let projectPath = session.projectPath {
            for (_, link) in linksById {
                if link.tmuxLink != nil,
                   link.sessionLink == nil,
                   link.isLaunching != true,
                   link.projectPath == projectPath {
                    ClaudeBoardLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by projectPath+tmux → card=\(link.id.prefix(12)) (tmux=\(link.tmuxLink?.sessionName ?? "?"))")
                    return link.id
                }
            }
        }

        // 3. Match by promptBody (manual card with same prompt, no sessionLink yet)
        //    Skip cards mid-launch — same reason as above
        if let firstPrompt = session.firstPrompt, !firstPrompt.isEmpty {
            for (_, link) in linksById {
                if link.sessionLink == nil,
                   link.isLaunching != true,
                   link.source == .manual,
                   let prompt = link.promptBody,
                   prompt == firstPrompt {
                    ClaudeBoardLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by promptBody → card=\(link.id.prefix(12))")
                    return link.id
                }
            }
        }

        // 4. Match by slug (context-continued session shares same conversation slug)
        if let slug = session.slug, !slug.isEmpty, let cardId = cardIdBySlug[slug] {
            ClaudeBoardLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by slug=\(slug) → card=\(cardId.prefix(12))")
            return cardId
        }

        ClaudeBoardLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) projectPath=\(session.projectPath ?? "nil") → NO MATCH")
        return nil
    }
}
