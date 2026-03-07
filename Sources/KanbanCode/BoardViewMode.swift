import SwiftUI
import KanbanCodeCore

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
    let column: KanbanCodeColumn
    let cards: [KanbanCodeCard]

    static func make(
        columns: [KanbanCodeColumn],
        cardsInColumn: (KanbanCodeColumn) -> [KanbanCodeCard]
    ) -> [ListBoardSection] {
        columns.map { column in
            ListBoardSection(column: column, cards: cardsInColumn(column))
        }
    }
}

enum ListSectionCollapseState {
    static func encode(_ columns: Set<KanbanCodeColumn>) -> String {
        columns.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func decode(_ rawValue: String) -> Set<KanbanCodeColumn> {
        Set(
            rawValue
                .split(separator: ",")
                .compactMap { KanbanCodeColumn(rawValue: String($0)) }
        )
    }
}
