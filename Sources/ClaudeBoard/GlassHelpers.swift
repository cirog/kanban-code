import SwiftUI

extension View {
    /// Apply liquid glass effect to a column.
    func glassColumn() -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

}
