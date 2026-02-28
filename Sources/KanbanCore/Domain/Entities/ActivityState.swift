import Foundation

/// Represents the current activity state of a Claude Code session.
public enum ActivityState: String, Codable, Sendable {
    /// Session is actively executing tools or generating output.
    case activelyWorking = "actively_working"
    /// Session stopped and is waiting for user input (plan approval, permission, done).
    case needsAttention = "needs_attention"
    /// Session has a running process but no recent activity.
    case idleWaiting = "idle_waiting"
    /// Session process has ended.
    case ended
    /// Session is old with no process, worktree, or tmux session.
    case stale
}
