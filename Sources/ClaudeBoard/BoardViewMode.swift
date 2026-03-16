import SwiftUI
import ClaudeBoardCore

enum BoardViewMode: String, CaseIterable {
    case kanban
    case list

    var label: String {
        switch self {
        case .kanban: "Kanban"
        case .list: "List"
        }
    }

    var icon: String {
        switch self {
        case .kanban: "square.split.2x1"
        case .list: "list.bullet"
        }
    }
}

struct ListBoardSection {
    let column: ClaudeBoardColumn
    let cards: [ClaudeBoardCard]

    static func make(
        columns: [ClaudeBoardColumn],
        cardsInColumn: (ClaudeBoardColumn) -> [ClaudeBoardCard]
    ) -> [ListBoardSection] {
        columns.map { column in
            ListBoardSection(column: column, cards: cardsInColumn(column))
        }
    }
}

enum ListSectionCollapseState {
    static func encode(_ columns: Set<ClaudeBoardColumn>) -> String {
        columns.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func decode(_ rawValue: String) -> Set<ClaudeBoardColumn> {
        Set(
            rawValue
                .split(separator: ",")
                .compactMap { ClaudeBoardColumn(rawValue: String($0)) }
        )
    }
}
