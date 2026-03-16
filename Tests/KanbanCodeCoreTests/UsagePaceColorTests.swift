import Testing
@testable import KanbanCodeCore

struct UsagePaceColorTests {
    @Test("Green when under pace")
    func greenUnderPace() {
        // 30% used, 50% elapsed → ratio 0.6 → green
        #expect(UsagePaceColor.calculate(utilization: 30, elapsedFraction: 0.5) == .green)
    }

    @Test("Orange when near pace")
    func orangeNearPace() {
        // 45% used, 50% elapsed → ratio 0.9 → orange
        #expect(UsagePaceColor.calculate(utilization: 45, elapsedFraction: 0.5) == .orange)
    }

    @Test("Red when over pace")
    func redOverPace() {
        // 80% used, 50% elapsed → ratio 1.6 → red
        #expect(UsagePaceColor.calculate(utilization: 80, elapsedFraction: 0.5) == .red)
    }

    @Test("Exactly at pace is red")
    func exactlyAtPace() {
        // 50% used, 50% elapsed → ratio 1.0 → red
        #expect(UsagePaceColor.calculate(utilization: 50, elapsedFraction: 0.5) == .red)
    }

    @Test("Green when just started")
    func greenJustStarted() {
        // Any utilization at start → green (guard)
        #expect(UsagePaceColor.calculate(utilization: 90, elapsedFraction: 0.005) == .green)
    }

    @Test("Green at zero utilization")
    func greenZeroUtilization() {
        #expect(UsagePaceColor.calculate(utilization: 0, elapsedFraction: 0.5) == .green)
    }
}
