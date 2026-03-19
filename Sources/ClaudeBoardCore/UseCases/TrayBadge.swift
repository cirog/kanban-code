import Foundation

/// Pure functions for system tray badge and visibility decisions.
/// Extracted from SystemTray for testability.
public enum TrayBadge {

    /// Badge text for the menu bar icon.
    /// Returns the count as a string when > 0, empty string otherwise.
    public static func badgeText(waitingCount: Int) -> String {
        waitingCount > 0 ? "\(waitingCount)" : ""
    }

    /// Whether the system tray icon should be visible.
    /// Visible when sessions are in progress, cards are waiting, or within linger timeout.
    public static func shouldShowTray(inProgressCount: Int, waitingCount: Int, isLingering: Bool) -> Bool {
        inProgressCount > 0 || waitingCount > 0 || isLingering
    }
}
