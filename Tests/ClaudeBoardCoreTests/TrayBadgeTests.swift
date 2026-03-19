import Testing
import Foundation
@testable import ClaudeBoardCore

@Suite("Tray Badge")
struct TrayBadgeTests {

    // MARK: - Badge text

    @Test("Badge text is empty when no waiting cards")
    func badgeTextEmpty() {
        #expect(TrayBadge.badgeText(waitingCount: 0) == "")
    }

    @Test("Badge text shows count when cards are waiting")
    func badgeTextWithCount() {
        #expect(TrayBadge.badgeText(waitingCount: 1) == "1")
        #expect(TrayBadge.badgeText(waitingCount: 3) == "3")
        #expect(TrayBadge.badgeText(waitingCount: 12) == "12")
    }

    // MARK: - Tray visibility

    @Test("Tray visible when cards are in progress")
    func visibleWithInProgress() {
        #expect(TrayBadge.shouldShowTray(inProgressCount: 1, waitingCount: 0, isLingering: false) == true)
    }

    @Test("Tray visible when cards are waiting even if nothing in progress")
    func visibleWithWaiting() {
        #expect(TrayBadge.shouldShowTray(inProgressCount: 0, waitingCount: 2, isLingering: false) == true)
    }

    @Test("Tray visible during linger timeout")
    func visibleDuringLinger() {
        #expect(TrayBadge.shouldShowTray(inProgressCount: 0, waitingCount: 0, isLingering: true) == true)
    }

    @Test("Tray hidden when nothing active, nothing waiting, not lingering")
    func hiddenWhenIdle() {
        #expect(TrayBadge.shouldShowTray(inProgressCount: 0, waitingCount: 0, isLingering: false) == false)
    }

    @Test("Tray visible when both in progress and waiting")
    func visibleWithBoth() {
        #expect(TrayBadge.shouldShowTray(inProgressCount: 2, waitingCount: 3, isLingering: false) == true)
    }
}
