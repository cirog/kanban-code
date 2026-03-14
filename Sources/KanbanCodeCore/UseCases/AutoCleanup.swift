import Foundation

public enum AutoCleanup {
    public static func clean(
        links: [Link],
        maxAgeDays: Int = 7,
        maxCards: Int = 1000
    ) -> [Link] {
        let cutoff = Date.now.addingTimeInterval(-Double(maxAgeDays) * 86400)

        var cleaned = links.filter { link in
            if link.column == .done && link.updatedAt < cutoff {
                return false
            }
            return true
        }

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
