import Foundation

/// Determines pace color for usage bars based on burn rate vs expected rate.
public enum UsagePaceColor: String, Sendable {
    case green, orange, red

    /// Calculate pace color from current utilization and elapsed fraction of the time window.
    /// - Parameters:
    ///   - utilization: 0-100 percentage used
    ///   - elapsedFraction: 0.0-1.0 how far through the time window (0 = just reset, 1 = about to reset)
    public static func calculate(utilization: Double, elapsedFraction: Double) -> UsagePaceColor {
        guard elapsedFraction > 0.01 else { return .green }
        let expectedUtilization = elapsedFraction * 100.0
        let ratio = utilization / expectedUtilization
        if ratio >= 1.0 { return .red }
        if ratio >= 0.8 { return .orange }
        return .green
    }
}
