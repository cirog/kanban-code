import SwiftUI
import AppKit
import SwiftTerm
import ClaudeBoardCore

// MARK: - Batched terminal view

/// Subclass that batches incoming pty data before feeding it to the terminal.
/// SwiftTerm's default path feeds each pty read (often tiny chunks) individually,
/// triggering a display update per chunk. This batches all data arriving within
/// a short window into a single feed, dramatically reducing redraws during
/// tmux resize/repaint and making scrolling feel instant like Warp.
///
/// LocalProcess dispatches each read via dispatchQueue.sync, so plain
/// DispatchQueue.main.async runs between chunks (FIFO). We use asyncAfter
/// with a short delay so multiple chunks accumulate before flushing.
final class BatchedTerminalView: LocalProcessTerminalView {
    private var pendingData: [UInt8] = []
    private var flushScheduled = false

    // 8ms batching window: LocalProcess dispatches dataReceived via
    // DispatchQueue.main.sync, so plain .async flushes interleave with
    // sync calls — each read gets its own flush, defeating batching.
    // asyncAfter lets many sync'd reads pile up before firing.
    private static let batchDelay: DispatchTimeInterval = .milliseconds(8)

    // Process in a loop with a time budget: keep feeding 32KB chunks
    // until we've spent ~4ms on the main thread, then yield. Most tmux
    // screen redraws (~50KB) finish in one shot (no flicker), but truly
    // huge batches yield periodically (no UI freeze).
    private static let chunkSize = 32 * 1024
    private static let maxBlockSeconds: Double = 0.004  // 4ms

    override func dataReceived(slice: ArraySlice<UInt8>) {
        pendingData.append(contentsOf: slice)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
            self?.processNextChunk()
        }
    }

    private func processNextChunk() {
        guard !pendingData.isEmpty else {
            flushScheduled = false
            return
        }

        let start = CACurrentMediaTime()

        while !pendingData.isEmpty {
            let count = min(Self.chunkSize, pendingData.count)
            let chunk = pendingData[..<count]
            feed(byteArray: chunk)
            pendingData.removeFirst(count)

            if !pendingData.isEmpty && CACurrentMediaTime() - start > Self.maxBlockSeconds {
                // Yield to runloop so the UI stays responsive
                DispatchQueue.main.async { [weak self] in
                    self?.processNextChunk()
                }
                return
            }
        }

        flushScheduled = false
    }

    /// Committed frame size — blocks sub-pixel resizes from reaching SwiftTerm's
    /// SIGWINCH handler, preventing tmux full-screen repaints during state updates.
    private var committedSize: NSSize = .zero

    override func setFrameSize(_ newSize: NSSize) {
        // Skip if same cell grid — prevents tmux SIGWINCH when SwiftUI
        // recreates the NSViewRepresentable and frame goes 0x0 → full size.
        if committedSize != .zero {
            let cs = cellSize
            if cs.width > 0 && cs.height > 0 {
                let oldCols = Int(committedSize.width / cs.width)
                let oldRows = Int(committedSize.height / cs.height)
                let newCols = Int(newSize.width / cs.width)
                let newRows = Int(newSize.height / cs.height)
                if oldCols == newCols && oldRows == newRows {
                    return  // same cell grid — no SIGWINCH needed
                }
            } else {
                let dw = abs(newSize.width - committedSize.width)
                let dh = abs(newSize.height - committedSize.height)
                if dw < 1.0 && dh < 1.0 {
                    return  // sub-pixel jitter fallback
                }
            }
        }
        committedSize = newSize
        super.setFrameSize(newSize)
    }

    // MARK: - Cmd+hover URL detection

    private static let urlRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"https?://[^\s\x00<>\"'\])\}]+"#,
            options: []
        )
    }()

    /// Currently highlighted URL range for underline drawing.
    private var highlightedURL: (screenRow: Int, colStart: Int, colEnd: Int, url: String)?
    private var urlHighlightLayer: CAShapeLayer?
    private var isCommandHeld = false
    private var urlEventMonitor: Any?

    func installURLMonitor() {
        guard urlEventMonitor == nil else { return }
        urlEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .mouseMoved, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  !self.isHidden,
                  self.window == event.window else { return event }
            // For mouse events, check the mouse is actually over this view
            if event.type != .flagsChanged {
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else {
                    // Mouse left this terminal — clear any highlight
                    if self.highlightedURL != nil { self.clearURLHighlight() }
                    return event
                }
            }
            return self.handleURLEvent(event)
        }
    }

    func removeURLMonitor() {
        if let monitor = urlEventMonitor {
            NSEvent.removeMonitor(monitor)
            urlEventMonitor = nil
        }
        clearURLHighlight()
    }

    private func handleURLEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            isCommandHeld = event.modifierFlags.contains(.command)
            if isCommandHeld {
                let pos = screenPosition(from: event)
                updateURLHighlight(col: pos.col, screenRow: pos.screenRow)
            } else {
                clearURLHighlight()
            }
            return event

        case .mouseMoved:
            if isCommandHeld {
                let pos = screenPosition(from: event)
                updateURLHighlight(col: pos.col, screenRow: pos.screenRow)
            }
            return event

        case .leftMouseUp:
            if event.modifierFlags.contains(.command) {
                let pos = screenPosition(from: event)
                if let detected = detectURL(col: pos.col, screenRow: pos.screenRow),
                   let url = URL(string: detected.url) {
                    clearURLHighlight()
                    NSWorkspace.shared.open(url)
                    return nil // consume the event
                }
            }
            return event

        default:
            return event
        }
    }

    /// Cell dimensions matching SwiftTerm's internal calculation.
    fileprivate var cellSize: CGSize {
        let f = font
        let glyph = f.glyph(withName: "W")
        let cw = f.advancement(forGlyph: glyph).width
        let ch = ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
        return CGSize(width: max(1, cw), height: max(1, ch))
    }

    /// Compute screen row (0-based from top) and col from mouse event.
    private func screenPosition(from event: NSEvent) -> (col: Int, screenRow: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let cols = terminal.cols
        let rows = terminal.rows
        guard cols > 0, rows > 0 else { return (0, 0) }
        let cs = cellSize
        let col = min(max(0, Int(point.x / cs.width)), cols - 1)
        let screenRow = min(max(0, Int((bounds.height - point.y) / cs.height)), rows - 1)
        return (col, screenRow)
    }

    /// Extract the URL under the cursor at the given screen position, if any.
    private func detectURL(col: Int, screenRow: Int) -> (url: String, colStart: Int, colEnd: Int)? {
        guard let regex = Self.urlRegex,
              let line = terminal.getLine(row: screenRow) else { return nil }
        let text = line.translateToString(trimRight: true)
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let range = match.range
            if col >= range.location && col < range.location + range.length {
                let url = nsText.substring(with: range)
                return (url, range.location, range.location + range.length - 1)
            }
        }
        return nil
    }

    private func updateURLHighlight(col: Int, screenRow: Int) {
        if let detected = detectURL(col: col, screenRow: screenRow) {
            if highlightedURL?.screenRow == screenRow,
               highlightedURL?.colStart == detected.colStart,
               highlightedURL?.colEnd == detected.colEnd { return }
            highlightedURL = (screenRow, detected.colStart, detected.colEnd, detected.url)
            drawURLHighlight(screenRow: screenRow, colStart: detected.colStart, colEnd: detected.colEnd)
            NSCursor.pointingHand.set()
        } else {
            clearURLHighlight()
        }
    }

    private func drawURLHighlight(screenRow: Int, colStart: Int, colEnd: Int) {
        urlHighlightLayer?.removeFromSuperlayer()
        let cs = cellSize
        let x = CGFloat(colStart) * cs.width
        // macOS origin is bottom-left; screenRow 0 = top of terminal
        let y = bounds.height - CGFloat(screenRow + 1) * cs.height
        let w = CGFloat(colEnd - colStart + 1) * cs.width

        let layer = CAShapeLayer()
        let underlineY = y + 1.0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: underlineY))
        path.addLine(to: CGPoint(x: x + w, y: underlineY))
        layer.path = path
        layer.strokeColor = NSColor.linkColor.cgColor
        layer.lineWidth = 1
        layer.fillColor = nil

        self.wantsLayer = true
        self.layer?.addSublayer(layer)
        urlHighlightLayer = layer
    }

    private func clearURLHighlight() {
        guard highlightedURL != nil else { return }
        highlightedURL = nil
        urlHighlightLayer?.removeFromSuperlayer()
        urlHighlightLayer = nil
        NSCursor.arrow.set()
    }

}

// MARK: - Terminal process cache

/// Caches tmux terminal views across drawer close/open cycles.
/// When the drawer closes, terminals are detached from the view hierarchy but kept alive.
/// When reopened, the cached terminal is reparented — no new tmux attach needed,
/// preserving scrollback and terminal state.
@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    static let defaultFontSize: CGFloat = 14
    static let fontSizeKey = "sessionDetailFontSize"

    private var terminals: [String: BatchedTerminalView] = [:]
    private var shiftEnterMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var fontSizeObserver: Any?

    private var currentFontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: TerminalCache.fontSizeKey)
        return stored > 0 ? CGFloat(stored) : TerminalCache.defaultFontSize
    }()

    /// Find the active (visible) session name for the terminal under the given window point.
    /// Bypasses hitTest which can be intercepted by SwiftUI overlay views.
    func sessionUnderPoint(_ windowPoint: NSPoint, in window: NSWindow) -> String? {
        for (sessionName, terminal) in terminals {
            guard !terminal.isHidden,
                  terminal.window == window else { continue }
            let localPoint = terminal.convert(windowPoint, from: nil)
            if terminal.bounds.contains(localPoint) {
                return sessionName
            }
        }
        return nil
    }

    /// Tracks tmux copy-mode state per session for scroll interception.
    fileprivate var copyModeSessions: Set<String> = []

    /// Cooldown: after exiting copy-mode, ignore scroll events briefly
    /// to prevent residual trackpad momentum from re-entering copy-mode.
    fileprivate var copyModeExitTime: [String: ContinuousClock.Instant] = [:]

    private init() {
        let tmux = Self.tmuxPath

        // Intercept keyDown events in terminal views for:
        // 1. Shift+Enter → send \n instead of \r (Claude Code newline vs submit)
        // 2. Any key while in copy-mode → exit copy-mode, let key through to shell
        shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let terminal = event.window?.firstResponder as? TerminalView else { return event }

            // Shift+Enter: send newline instead of carriage return
            if event.keyCode == 36, event.modifierFlags.contains(.shift) {
                terminal.send([0x0a])
                return nil
            }

            guard let self else { return event }

            // Find the session for this terminal
            var view: NSView? = terminal
            while let v = view, !(v is TerminalContainerNSView) {
                view = v.superview
            }
            guard let container = view as? TerminalContainerNSView,
                  let session = container.activeSession else { return event }

            // If in copy-mode, exit it on any non-modifier keypress and let the
            // key flow through to the terminal normally (no consumption).
            if self.copyModeSessions.contains(session) {
                let modifiers = event.modifierFlags.intersection([.command, .option, .control])
                guard modifiers.isEmpty else { return event }

                self.copyModeSessions.remove(session)
                self.copyModeExitTime[session] = .now

                // Fire-and-forget: exit copy-mode in tmux
                Task.detached {
                    _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "cancel"])
                }

                // Let the key through to SwiftTerm — it will reach the shell
                // directly via the PTY, so the user's typing is never lost.
                return event
            }

            return event
        }

        // Intercept scroll wheel events over terminal views and translate to tmux
        // copy-mode scrolling. Tmux owns the scrollback buffer, so SwiftTerm's
        // native scroll has nothing to scroll through.
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.deltaY != 0 else { return event }

            guard let window = event.window else { return event }
            guard let session = self?.sessionUnderPoint(event.locationInWindow, in: window) else { return event }

            let inCopyMode = self?.copyModeSessions.contains(session) ?? false

            // After exiting copy-mode, ignore scroll events for 500ms
            // to prevent residual trackpad momentum from re-entering.
            if let exitTime = self?.copyModeExitTime[session],
               exitTime.duration(to: .now) < .milliseconds(500) {
                return nil
            }

            if event.deltaY > 0 {
                // Scroll UP — enter copy-mode if needed, then scroll.
                let lines = max(1, Int(abs(event.deltaY)))
                if !inCopyMode {
                    self?.copyModeSessions.insert(session)
                    Task.detached {
                        _ = try? await ShellCommand.run(tmux, arguments: ["copy-mode", "-t", session])
                        _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-up"])
                    }
                } else {
                    Task.detached {
                        _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-up"])
                    }
                }
            } else if inCopyMode {
                // Scroll DOWN in copy-mode. Auto-exit when reaching bottom.
                let lines = max(1, Int(abs(event.deltaY)))
                Task.detached {
                    _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-down"])
                    try? await Task.sleep(for: .milliseconds(50))
                    let result = try? await ShellCommand.run(
                        tmux, arguments: ["display-message", "-p", "-t", session, "#{scroll_position}"]
                    )
                    if result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                        let shouldExit = await MainActor.run {
                            guard TerminalCache.shared.copyModeSessions.remove(session) != nil else { return false }
                            TerminalCache.shared.copyModeExitTime[session] = .now
                            return true
                        }
                        if shouldExit {
                            _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "cancel"])
                        }
                    }
                }
            }

            return nil // consume — don't let SwiftTerm handle it
        }

        // Observe font size changes from Settings / Cmd+Plus/Minus
        fontSizeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyFontSizeIfChanged()
            }
        }
    }

    private func applyFontSizeIfChanged() {
        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        let newSize = stored > 0 ? CGFloat(stored) : Self.defaultFontSize
        guard newSize != currentFontSize else { return }
        currentFontSize = newSize
        let font = NSFont(name: "JetBrains Mono", size: newSize)
            ?? NSFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
        for terminal in terminals.values {
            terminal.font = font
        }
    }

    /// Tracks which terminals have had their process started.
    private var startedSessions: Set<String> = []

    /// Resolved tmux binary path — checked once, reused for all terminals.
    static let tmuxPath: String = ShellCommand.findExecutable("tmux") ?? "tmux"

    /// Get or create a terminal view for the given tmux session name.
    /// The process is NOT started here — call `startProcessIfNeeded` after layout
    /// so the terminal has a non-zero frame (avoids tmux SIGWINCH clear on resize from 0x0).
    func terminal(for sessionName: String, frame: NSRect) -> BatchedTerminalView {
        if let existing = terminals[sessionName] {
            return existing
        }
        let terminal = BatchedTerminalView(frame: frame)
        // Dracula theme colors
        terminal.nativeBackgroundColor = NSColor(red: 0x28/255.0, green: 0x2A/255.0, blue: 0x36/255.0, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0xF8/255.0, green: 0xF8/255.0, blue: 0xF2/255.0, alpha: 1.0)
        terminal.caretColor = NSColor(red: 0xF8/255.0, green: 0xF8/255.0, blue: 0xF2/255.0, alpha: 1.0)

        // Dracula ANSI palette (SwiftTerm Color uses UInt16 0-65535, multiply 0-255 by 257)
        let c = { (r: UInt16, g: UInt16, b: UInt16) in SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257) }
        terminal.installColors([
            // Standard colors (0-7)
            c(0x21, 0x22, 0x2C),  // black
            c(0xFF, 0x55, 0x55),  // red
            c(0x50, 0xFA, 0x7B),  // green
            c(0xF1, 0xFA, 0x8C),  // yellow
            c(0xBD, 0x93, 0xF9),  // blue (purple in Dracula)
            c(0xFF, 0x79, 0xC6),  // magenta (pink)
            c(0x8B, 0xE9, 0xFD),  // cyan
            c(0xF8, 0xF8, 0xF2),  // white
            // Bright colors (8-15)
            c(0x62, 0x72, 0xA4),  // bright black (comment)
            c(0xFF, 0x6E, 0x6E),  // bright red
            c(0x69, 0xFF, 0x94),  // bright green
            c(0xFF, 0xFF, 0xA5),  // bright yellow
            c(0xD6, 0xAC, 0xFF),  // bright blue (bright purple)
            c(0xFF, 0x92, 0xDF),  // bright magenta (bright pink)
            c(0xA4, 0xFF, 0xFF),  // bright cyan
            c(0xFF, 0xFF, 0xFF),  // bright white
        ])

        terminal.font = NSFont(name: "JetBrains Mono", size: currentFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)

        // Do NOT set autoresizingMask — we manage frame explicitly in layout()
        // to avoid intermediate sizes triggering tmux redraws during animations.
        terminal.autoresizingMask = []
        terminal.isHidden = true
        terminal.installURLMonitor()
        terminals[sessionName] = terminal
        return terminal
    }

    /// Start the tmux attach process if the terminal has a non-zero frame and hasn't started yet.
    func startProcessIfNeeded(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        guard !startedSessions.contains(sessionName) else { return }
        guard terminal.frame.width > 0, terminal.frame.height > 0 else { return }
        startedSessions.insert(sessionName)

        let escaped = sessionName.replacingOccurrences(of: "'", with: "'\\''")
        let tmux = Self.tmuxPath
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(
            executable: userShell,
            args: ["-l", "-c", "for i in $(seq 1 50); do '\(tmux)' has-session -t '\(escaped)' 2>/dev/null && break; sleep 0.1; done; exec '\(tmux)' attach-session -t '\(escaped)'"],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )
    }

    /// Remove and terminate a specific terminal (e.g., when user kills a session).
    func remove(_ sessionName: String) {
        startedSessions.remove(sessionName)
        if let terminal = terminals.removeValue(forKey: sessionName) {
            terminal.removeURLMonitor()
            terminal.removeFromSuperview()
            terminal.terminate()
        }
    }

    /// Check if a terminal exists for this session.
    func has(_ sessionName: String) -> Bool {
        terminals[sessionName] != nil
    }

    /// Focus the terminal for a session directly (bypasses NSViewRepresentable update).
    func focusTerminal(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak terminal] in
            guard let terminal, terminal.window?.firstResponder !== terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

// MARK: - Multi-terminal container (manages all terminals for a card)

/// A single NSViewRepresentable that manages multiple tmux terminal subviews.
/// Uses TerminalCache to persist terminals across drawer close/open cycles.
/// Terminals are created once globally and reparented as needed — never destroyed
/// just because the drawer was toggled.
struct TerminalContainerView: NSViewRepresentable, Equatable {
    /// All tmux session names to show tabs for.
    let sessions: [String]
    /// Which session is currently visible.
    let activeSession: String
    /// When true, the terminal grabs keyboard focus (user clicked a tab).
    /// When false, the terminal is shown but focus stays where it was (keyboard nav, drawer open).
    var grabFocus: Bool = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Ultra-strict: only sessions matter. grabFocus changes should NOT
        // trigger updateNSView — we handle focus separately.
        lhs.sessions == rhs.sessions
            && lhs.activeSession == rhs.activeSession
    }

    /// Coordinator owns the TerminalContainerNSView. Created once per SwiftUI
    /// structural identity — survives across updateNSView calls. Eliminates the
    /// singleton container pattern where ghost views fought over shared state.
    @MainActor
    class Coordinator {
        let container = TerminalContainerNSView()
        var lastSessions: [String] = []
        var lastActiveSession: String = ""
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalContainerNSView {
        let container = context.coordinator.container
        for session in sessions {
            container.ensureTerminal(for: session)
        }
        container.showTerminal(for: activeSession, grabFocus: grabFocus)
        context.coordinator.lastSessions = sessions
        context.coordinator.lastActiveSession = activeSession
        return container
    }

    func updateNSView(_ nsView: TerminalContainerNSView, context: Context) {
        let coordinator = context.coordinator

        // When sessions are empty (terminal not yet created), just clean up and return.
        guard !sessions.isEmpty, !activeSession.isEmpty else {
            nsView.removeTerminalsNotIn([])
            coordinator.lastSessions = []
            coordinator.lastActiveSession = ""
            return
        }

        // Only add/remove sessions if the list changed
        if coordinator.lastSessions != sessions {
            for session in sessions {
                nsView.ensureTerminal(for: session)
            }
            nsView.removeTerminalsNotIn(Set(sessions))
            coordinator.lastSessions = sessions
        }

        // Only switch active session if it changed
        if coordinator.lastActiveSession != activeSession || grabFocus {
            nsView.showTerminal(for: activeSession, grabFocus: grabFocus)
            coordinator.lastActiveSession = activeSession
        }
    }

    static func dismantleNSView(_ nsView: TerminalContainerNSView, coordinator: Coordinator) {
        // Detach terminals from this container but don't terminate them.
        // They live in TerminalCache and will be re-parented by the next Coordinator.
        nsView.detachAll()
    }
}

/// AppKit container that owns multiple LocalProcessTerminalView instances.
/// Uses TerminalCache for process lifecycle — terminal processes survive view teardown.
final class TerminalContainerNSView: NSView {
    private static let terminalPadding: CGFloat = 6

    /// Ordered list of session names managed by this container.
    private var managedSessions: [String] = []
    fileprivate private(set) var activeSession: String?
    /// Timestamp of last session switch — prevents oscillation from SwiftUI ghost views.
    private var lastSwitchTime: ContinuousClock.Instant = .now

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x28/255.0, green: 0x2A/255.0, blue: 0x36/255.0, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x28/255.0, green: 0x2A/255.0, blue: 0x36/255.0, alpha: 1.0).cgColor
    }

    /// Ensure a terminal for `sessionName` is attached to this container.
    func ensureTerminal(for sessionName: String) {
        guard !managedSessions.contains(sessionName) else { return }
        let terminal = TerminalCache.shared.terminal(for: sessionName, frame: bounds)
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            // Pre-set the correct inset frame BEFORE adding to the view hierarchy.
            // This prevents the initial layout pass from triggering a resize from
            // (0,0,full_bounds) → (inset) which would cause SIGWINCH.
            let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
            if inset.width > 0 && inset.height > 0 {
                terminal.frame = inset
            }
            addSubview(terminal)
        }
        // Show immediately with old content — no hiding/alpha tricks.
        // Combined with BatchedTerminalView, any tmux redraw lands as
        // one batched update instead of visible scrolling.
        terminal.isHidden = true
        managedSessions.append(sessionName)
    }

    /// Show only the terminal for `sessionName`, hide all others.
    func showTerminal(for sessionName: String, grabFocus: Bool = false) {
        // Skip if already showing this session
        if activeSession == sessionName && !grabFocus {
            let terminal = TerminalCache.shared.terminal(for: sessionName, frame: bounds)
            if !terminal.isHidden { return }
        }
        // Debounce rapid switches — SwiftUI ghost views during card rebuilds
        // cause two different cards to alternate showTerminal calls. Only
        // allow a switch to a DIFFERENT session if >200ms since last switch.
        if activeSession != nil && activeSession != sessionName && !grabFocus {
            if lastSwitchTime.duration(to: .now) < .milliseconds(200) {
                return  // suppress ghost view oscillation
            }
        }
        lastSwitchTime = .now
        activeSession = sessionName
        for name in managedSessions {
            let terminal = TerminalCache.shared.terminal(for: name, frame: bounds)
            let isActive = (name == sessionName)
            if isActive {
                // Delay unhide by 50ms to let layout settle before showing,
                // preventing flash of mispositioned content during session switch.
                if terminal.isHidden {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        terminal.isHidden = false
                    }
                }
            } else if !terminal.isHidden {
                terminal.isHidden = true
            }
            if isActive {
                disableScrollbar(on: terminal)
                if grabFocus {
                    // Try immediately, then retry after a delay for heavy cards
                    // where SwiftUI re-renders steal focus during history loading.
                    DispatchQueue.main.async { [weak self] in
                        self?.window?.makeFirstResponder(terminal)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.activeSession == sessionName,
                              self.window?.firstResponder !== terminal else { return }
                        self.window?.makeFirstResponder(terminal)
                    }
                }
            }
        }
    }

    /// Hide SwiftTerm's built-in NSScroller.
    private func disableScrollbar(on terminal: NSView) {
        for subview in terminal.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            }
        }
    }

    /// Remove terminals whose session names are not in `keep`.
    func removeTerminalsNotIn(_ keep: Set<String>) {
        let toRemove = managedSessions.filter { !keep.contains($0) }
        for name in toRemove {
            TerminalCache.shared.remove(name)
            managedSessions.removeAll { $0 == name }
        }
    }

    /// Detach all terminals from this container without terminating them.
    func detachAll() {
        for sub in subviews {
            sub.removeFromSuperview()
        }
        managedSessions.removeAll()
        activeSession = nil
    }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
        guard inset.width > 0, inset.height > 0 else { return }

        for sub in subviews {
            if let terminal = sub as? BatchedTerminalView {
                let cs = terminal.cellSize
                guard cs.width > 0, cs.height > 0 else { continue }

                // Quantize to cell grid: round dimensions down to whole cell multiples.
                // This prevents oscillation where layout alternates between N and N+1 rows
                // due to header content changes — tmux only sees stable grid dimensions.
                let cols = Int(inset.width / cs.width)
                let rows = Int(inset.height / cs.height)
                let quantizedWidth = CGFloat(cols) * cs.width
                let quantizedHeight = CGFloat(rows) * cs.height
                let quantized = NSRect(
                    x: inset.origin.x,
                    y: inset.origin.y + (inset.height - quantizedHeight),
                    width: quantizedWidth,
                    height: quantizedHeight
                )

                let oldCols = Int(sub.frame.width / cs.width)
                let oldRows = Int(sub.frame.height / cs.height)
                guard oldCols != cols || oldRows != rows else { continue }
                ClaudeBoardLog.info("terminal-layout", "RESIZE \(oldCols)x\(oldRows) → \(cols)x\(rows)")
                sub.frame = quantized
            } else {
                let delta = abs(sub.frame.width - inset.width) + abs(sub.frame.height - inset.height)
                guard delta >= 1.0 else { continue }
                sub.frame = inset
            }
        }

        for name in managedSessions {
            TerminalCache.shared.startProcessIfNeeded(for: name)
        }
    }

}
