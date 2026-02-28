import SwiftUI
import AppKit
import KanbanCore

/// Manages the menu bar status item (system tray).
@MainActor
final class SystemTray: @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private weak var boardState: BoardState?

    func setup(boardState: BoardState) {
        self.boardState = boardState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Kanban")
        statusItem?.button?.image?.size = NSSize(width: 18, height: 18)

        updateMenu()
    }

    func updateMenu() {
        let menu = NSMenu()

        // Active sessions
        if let state = boardState {
            let activeCards = state.cards(in: .inProgress)
            let attentionCards = state.cards(in: .requiresAttention)

            if !activeCards.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(withTitle: "In Progress"))
                for card in activeCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }

            if !attentionCards.isEmpty {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem.sectionHeader(withTitle: "Requires Attention"))
                for card in attentionCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }

            if activeCards.isEmpty && attentionCards.isEmpty {
                let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
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

    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Show or hide the tray icon based on active sessions.
    func updateVisibility(hasActiveSessions: Bool) {
        statusItem?.isVisible = hasActiveSessions
    }
}
