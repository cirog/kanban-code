import Foundation

public enum AutoCleanup {
    public static func clean(
        links: [Link],
        maxAgeHours: Int = 72,
        maxCards: Int = 1000
    ) -> [Link] {
        let cutoff = Date.now.addingTimeInterval(-Double(maxAgeHours) * 3600)

        // Move scheduled tasks and summary sessions from waiting/inProgress to done
        var cleaned = links.map { link -> Link in
            if link.column == .waiting || link.column == .inProgress {
                let text = [link.name, link.promptBody]
                    .compactMap { $0 }
                    .first { !$0.isEmpty && ($0.hasPrefix("<scheduled-task name=") || $0.hasPrefix("[CB-SUMMARY]")) }
                if text != nil {
                    var updated = link
                    updated.column = .done
                    return updated
                }
            }
            return link
        }

        // Remove old Done cards (any source)
        cleaned = cleaned.filter { link in
            if link.column == .done && link.updatedAt < cutoff {
                return false
            }
            return true
        }

        // Cap total count — remove oldest Done cards first
        if cleaned.count > maxCards {
            let doneCards = cleaned.filter { $0.column == .done }
                .sorted { $0.updatedAt < $1.updatedAt }
            let toRemove = cleaned.count - maxCards
            let removeIds = Set(doneCards.prefix(toRemove).map(\.id))
            cleaned = cleaned.filter { !removeIds.contains($0.id) }
        }

        return cleaned
    }
}
