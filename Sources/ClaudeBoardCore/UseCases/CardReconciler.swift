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

    /// Reconcile existing cards with discovered resources.
    /// Returns the merged list of links (some updated, some new, some with cleared links).
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> [Link] {
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
                    var prevPaths = link.sessionLink?.previousSessionPaths ?? []
                    if let oldPath = link.sessionLink?.sessionPath {
                        prevPaths.append(oldPath)
                    }
                    link.sessionLink = SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath,
                        slug: session.slug,
                        previousSessionPaths: prevPaths.isEmpty ? nil : prevPaths
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

        // B. Merge cards that share the same slug (handles sessions discovered in same batch)
        mergeDuplicateSlugs(&linksById)

        // C. Clear dead tmux links
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))
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

        return Array(linksById.values)
    }

    // MARK: - Slug Merge

    /// Merge cards that ended up with the same slug on separate cards.
    /// This happens when multiple context-continued sessions are discovered in the same batch —
    /// each gets its own card via sessionId match, but they logically belong together.
    private static func mergeDuplicateSlugs(_ linksById: inout [String: Link]) {
        // Group non-archived cards by slug
        var cardsBySlug: [String: [String]] = [:] // slug → [cardId]
        for (id, link) in linksById {
            guard !link.manuallyArchived,
                  let slug = link.sessionLink?.slug, !slug.isEmpty else { continue }
            cardsBySlug[slug, default: []].append(id)
        }

        for (slug, cardIds) in cardsBySlug where cardIds.count > 1 {
            // Pick survivor: prefer card with manual overrides (name, column), then most recent activity
            let sorted = cardIds.compactMap { linksById[$0] }.sorted { a, b in
                let aHasOverrides = a.manualOverrides.name || a.manualOverrides.column
                let bHasOverrides = b.manualOverrides.name || b.manualOverrides.column
                if aHasOverrides != bHasOverrides { return aHasOverrides }
                return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
            }

            guard var survivor = sorted.first else { continue }
            let losers = sorted.dropFirst()

            // Collect all session paths from losers into previousSessionPaths
            var prevPaths = survivor.sessionLink?.previousSessionPaths ?? []
            for loser in losers {
                if let path = loser.sessionLink?.sessionPath {
                    prevPaths.append(path)
                }
                if let loserPrev = loser.sessionLink?.previousSessionPaths {
                    prevPaths.append(contentsOf: loserPrev)
                }
                // Absorb tmuxLink if survivor doesn't have one
                if survivor.tmuxLink == nil, let tmux = loser.tmuxLink {
                    survivor.tmuxLink = tmux
                }
                // Absorb queued prompts
                if let prompts = loser.queuedPrompts {
                    survivor.queuedPrompts = (survivor.queuedPrompts ?? []) + prompts
                }
                // Remove loser
                linksById.removeValue(forKey: loser.id)
            }

            survivor.sessionLink?.previousSessionPaths = prevPaths.isEmpty ? nil : prevPaths
            // Update activity to most recent across all merged cards
            if let newestActivity = sorted.compactMap(\.lastActivity).max() {
                survivor.lastActivity = newestActivity
            }
            linksById[survivor.id] = survivor

            ClaudeBoardLog.info("reconciler", "Merged \(cardIds.count) cards with slug=\(slug) → survivor=\(survivor.id.prefix(12))")
        }
    }

    // MARK: - Private

    /// Find an existing card that should own this session.
    /// Match priority: exact sessionId → project path + tmux → promptBody → slug.
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
