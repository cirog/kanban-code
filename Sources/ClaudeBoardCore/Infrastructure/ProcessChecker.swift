import Foundation

/// Check if a process is alive using kill(pid, 0).
public enum ProcessChecker {
    /// Returns true if the process with the given PID is alive.
    public static func isAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }
}
