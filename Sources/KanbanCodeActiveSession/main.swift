import AppKit

// Tiny background-only app visible in Activity Monitor as a marker that
// an assistant session is running. Tools like Amphetamine can detect it.
// Kanban Code launches this .app bundle when Claude sessions are active.
// LSUIElement in Info.plist keeps it out of the Dock.
// NSApplication handles SIGTERM/terminate() properly.

let app = NSApplication.shared
app.run()
