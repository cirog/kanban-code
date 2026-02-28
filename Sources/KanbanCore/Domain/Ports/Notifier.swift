import Foundation

/// Port for sending notifications to the user.
public protocol NotifierPort: Sendable {
    /// Send a notification with optional image attachment.
    func sendNotification(title: String, message: String, imageData: Data?) async throws

    /// Check if this notifier is configured and ready.
    func isConfigured() -> Bool
}
