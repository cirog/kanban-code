import Foundation
import CoreGraphics

/// Pure state tracker for terminal overlay. Detects changes so the AppKit layer
/// only redraws when needed. No AppKit dependency — testable in Core.
public struct TerminalOverlayState: Sendable {
    public var sessions: [String] = []
    public var activeSession: String?
    public var frame: CGRect = .zero

    public init() {}

    /// Update state. Returns true if anything changed.
    @discardableResult
    public mutating func update(sessions: [String], active: String?, frame: CGRect) -> Bool {
        let changed = self.sessions != sessions
            || self.activeSession != active
            || self.frame != frame
        self.sessions = sessions
        self.activeSession = active
        self.frame = frame
        return changed
    }
}
