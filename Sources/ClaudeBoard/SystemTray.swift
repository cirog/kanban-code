import SwiftUI
import AppKit
import ClaudeBoardCore

private let systemTrayLogDir: String = {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

/// Manages the menu bar status item (system tray).
/// Shows session icon when Claude sessions are actively working.
@MainActor
final class SystemTray: NSObject, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private weak var store: BoardStore?
    /// Time when In Progress last had sessions (for linger timeout).
    private var lastActiveTime: Date?
    /// Timer for live-updating the countdown while menu is open.
    private var countdownTimer: Timer?
    /// Reference to the countdown menu item for live updates.
    private weak var countdownItem: NSMenuItem?

    /// How long to keep tray visible after last active session.
    private var lingerTimeout: TimeInterval { 60 }

    func setup(store: BoardStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build icon with 1x + 2x representations for crisp rendering at 22x22pt
        // Build 1x + 2x representations for crisp rendering at 22x22pt
        let icon = NSImage(size: NSSize(width: 22, height: 22))
        var hasReps = false

        if let url = Bundle.appResources.url(forResource: "clawd", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22)
            icon.addRepresentation(rep)
            hasReps = true
        }
        if let url = Bundle.appResources.url(forResource: "clawd@2x", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22) // same logical size; 44px used on retina
            icon.addRepresentation(rep)
            hasReps = true
        }

        if hasReps {
            icon.isTemplate = true
            statusItem?.button?.image = icon
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Kanban")
        }

        updateMenu()
        updateBadge()
        updateVisibility()
    }

    func update() {
        updateMenu()
        updateBadge()
        updateVisibility()
    }

    private func updateMenu() {
        let menu = NSMenu()
        menu.delegate = self

        if let store {
            let activeCards = store.state.cards(in: .inProgress)
            let attentionCards = store.state.cards(in: .waiting)

            // Countdown at the top when lingering (no active sessions)
            if activeCards.isEmpty {
                let item = NSMenuItem(title: countdownText(), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                countdownItem = item
                if !attentionCards.isEmpty {
                    menu.addItem(NSMenuItem.separator())
                }
            }

            if !activeCards.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "In Progress"))
                for card in activeCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    if card.isActivelyWorking {
                        item.image = NSImage(systemSymbolName: "gear.circle.fill", accessibilityDescription: nil)
                    } else {
                        item.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
                    }
                    menu.addItem(item)
                }
            }

            if !attentionCards.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "Waiting"))
                for card in attentionCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Kanban", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    private func countdownText() -> String {
        guard let lastActive = lastActiveTime else {
            return "No active sessions"
        }
        let elapsed = Date().timeIntervalSince(lastActive)
        let remaining = max(0, Int(lingerTimeout - elapsed))
        let mins = remaining / 60
        let secs = remaining % 60
        let countdown = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
        return "No active sessions, sleeping in \(countdown)"
    }

    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Update the badge text on the menu bar icon.
    private func updateBadge() {
        guard let store else { return }
        let waitingCount = store.state.cardCount(in: .waiting)
        let badge = TrayBadge.badgeText(waitingCount: waitingCount)
        statusItem?.button?.title = badge
        statusItem?.button?.imagePosition = badge.isEmpty ? .imageOnly : .imageLeading
    }

    /// Show tray icon when there are In Progress sessions, waiting cards, or within linger timeout.
    private func updateVisibility() {
        guard let store else { return }
        let inProgressCount = store.state.cardCount(in: .inProgress)
        let waitingCount = store.state.cardCount(in: .waiting)

        if inProgressCount > 0 {
            lastActiveTime = Date()
        }

        let isLingering: Bool
        if let lastActive = lastActiveTime {
            isLingering = Date().timeIntervalSince(lastActive) < lingerTimeout
        } else {
            isLingering = false
        }

        statusItem?.isVisible = TrayBadge.shouldShowTray(
            inProgressCount: inProgressCount,
            waitingCount: waitingCount,
            isLingering: isLingering
        )
    }

    // MARK: - Logging

    nonisolated static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let logPath = (systemTrayLogDir as NSString).appendingPathComponent("kanban.log")
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

}

// MARK: - NSMenuDelegate (live countdown)

extension SystemTray: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
            guard countdownItem != nil else { return }
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.countdownItem?.title = self?.countdownText() ?? ""
                }
            }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }
}
