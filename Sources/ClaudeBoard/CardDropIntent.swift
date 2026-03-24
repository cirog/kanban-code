import ClaudeBoardCore

enum CardDropIntent: Equatable {
    case move
    case start
    case resume
    case archive
    case invalid(String)

    var isAllowed: Bool {
        if case .invalid = self {
            return false
        }
        return true
    }

    static func resolve(_ card: ClaudeBoardCard, to column: ClaudeBoardColumn) -> CardDropIntent {
        switch column {
        case .inProgress:
            if card.link.tmuxLink != nil {
                return .invalid("Session is already running - card moves to In Progress automatically when Claude is actively working")
            }
            if card.column == .backlog && card.session == nil {
                return .start
            }
            if card.session != nil {
                return .resume
            }
            return .move

        case .done:
            return .archive

        case .backlog, .waiting:
            return .move
        }
    }
}
