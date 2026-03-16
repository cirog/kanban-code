import SwiftUI

extension View {
    /// Apply liquid glass effect to a column.
    func glassColumn() -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Apply liquid glass effect to a search/modal overlay.
    func glassOverlay() -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Extend background under glass for visual continuity.
    func extendedBackground() -> some View {
        self.backgroundExtensionEffect()
    }
}
