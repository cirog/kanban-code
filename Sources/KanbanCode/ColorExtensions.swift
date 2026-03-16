import SwiftUI
import KanbanCodeCore

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

// MARK: - Dracula Theme

extension Color {
    /// Dracula background — app chrome, window background
    static let draculaBg = Color(hex: "#2B2D42")
    /// Cards, note pad, elevated surfaces
    static let draculaSurface = Color(hex: "#333654")
    /// Selected/highlighted items, code blocks
    static let draculaCurrentLine = Color(hex: "#44475A")
}

// MARK: - Project Color Environment

/// Maps project path → hex color string. Set at top level, read by CardView.
struct ProjectColorMapKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

/// Project labels for card categorization. Set at top level, read by CardView.
struct ProjectLabelsKey: EnvironmentKey {
    static let defaultValue: [ProjectLabel] = []
}

extension EnvironmentValues {
    var projectColorMap: [String: String] {
        get { self[ProjectColorMapKey.self] }
        set { self[ProjectColorMapKey.self] = newValue }
    }

    var projectLabels: [ProjectLabel] {
        get { self[ProjectLabelsKey.self] }
        set { self[ProjectLabelsKey.self] = newValue }
    }
}
