# Lost Features Reimplementation Design

**Date:** 2026-03-16
**Context:** The `/tmp/kanban-code` working directory was cleared before unpushed commits from 2026-03-15 were pushed. The repo on GitHub only has up to commit `338c8cc` (Todoist integration design doc). All implementation code for 10 features is lost and must be reimplemented.

## Features (in implementation order)

### 1. Todoist Integration

**New files:**
- `Sources/KanbanCodeCore/Infrastructure/TodoistSyncService.swift` — actor, polls `todoist task list --label claude --format json` every 5min + on startup

**Model changes (Link.swift):**
- Add `todoistId: String?`, `todoistDescription: String?`
- Add `.todoist` case to `LinkSource` enum

**BoardStore changes:**
- New actions: `todoistSyncCompleted([TodoistTask])`, `completeTodoistTask(linkId: String)`
- Reducer: merge synced tasks into links (match by `todoistId`, create new if not found)
- Effect: `.completeTodoistTask(id)` → shell `todoist task complete --ids <id>`

**AssignColumn:** Preserve `.todoist` source cards (currently only preserves `.manual`)

**CardDetailView:** New `.description` tab visible when `link.todoistDescription != nil`

**CardView:** `checkmark.circle` SF Symbol when `link.todoistId != nil`

**BackgroundOrchestrator:** Trigger sync on 5min interval (reuse existing tick, count modulo)

### 2. Projects as Labels

**Replace `Project` entity** with `ProjectLabel`:
```swift
struct ProjectLabel: Codable, Identifiable, Hashable {
    let id: String  // KSUID
    var name: String
    var color: String  // hex
    var description: String?
}
```

**Link.swift:** Replace `projectPath: String?` with `projectId: String?`

**Remove:** `ProjectDiscovery.swift`, `excludedPaths`, `moveCardToProject/Folder`, project filtering logic in BoardStore

**Settings:** `projectLabels: [ProjectLabel]` persisted in settings.json. CRUD with `settingsChanged` notification.

**UI:**
- CardView: 4px left accent border using project color
- Context menu: "Set Project" submenu listing all labels
- Toolbar: dropdown button with color dots + "New Project..." sheet
- SettingsView: label list with inline color picker grid (add/edit/delete)

### 3. Usage Bar Pace Coloring

In the usage bar view (toolbar), calculate pace ratio:
```
ratio = actual_utilization / expected_utilization_at_elapsed_time
```
- Green: ratio < 0.8
- Orange: 0.8 ≤ ratio < 1.0
- Red: ratio ≥ 1.0

Apply to both 5h and 7d progress bars.

### 4. Compact Cards

Strip `CardView` to minimum:
- Remove: folder/path label, Todoist checkmark icon row, `CardBadgesRow` (git branch, message count)
- Keep: title text, activity state icon/badge, relative time, project color accent

### 5. Card Note Pad

**Link.swift:** Add `notes: String?` field

**UI:** Below the board columns HStack (in ContentView), a collapsible text editor:
- `TextEditor` bound to selected card's `link.notes`
- `maxHeight: 500px`
- Two buttons: "Copy" (pasteboard) + "Push to Terminal" (tmux send-keys + clear)
- Only visible when a card is selected

### 6. Summary Tab

**CardDetailView:** New `.summary` tab
- `@State var summaryText: String?`, `@State var isLoadingSummary: Bool`
- On tab appear: read last 10 turns from JSONL, run `claude -p --model sonnet` with summarization prompt
- Display 3-5 bullet summary
- Ephemeral — not saved to Link
- `AutoCleanup` handles the summary helper session files

### 7. macOS Notifications (UNUserNotificationCenter)

**Replace** `MacOSNotificationClient` internals with `UNUserNotificationCenter`:
- Request authorization on app launch
- Set `UNUserNotificationCenterDelegate` to handle click → select card
- Notification userInfo carries `linkId` for card selection

**Deploy:** Add `codesign -s - --force --deep` to Makefile deploy target

### 8. App Icon

- Load `assets/logo.png` at runtime
- Set `NSApp.applicationIconImage = NSImage(contentsOfFile: logoPath)` in App.swift onAppear
- Bypasses macOS icon cache for the old KanbanCode bundle

### 9. Prompt Timeline Tab

**Replace** the prompt editor in `.prompt` tab with a timeline view:

**New infrastructure:**
- `JsonlParser.parseLocalCommandArgs(_:)` — extract `<command-args>` XML tag content
- `TranscriptReader.extractUserBlocks` — append command args to slash command text

**CardDetailView `.prompt` tab:**
- Load all conversation turns, filter to `role == "user"` excluding `[tool result` prefix
- Show original prompt (from `link.promptBody`) at top with distinct background
- Chronological list: monospaced timestamp + text preview (truncated)
- Timestamp format: HH:mm for same-day, MMM dd HH:mm otherwise
- Header with "Copy All" button

### 10. Terminal Jitter Fix

**BatchedTerminalView:**
```swift
private var committedSize: NSSize = .zero

override func setFrameSize(_ newSize: NSSize) {
    let dw = abs(newSize.width - committedSize.width)
    let dh = abs(newSize.height - committedSize.height)
    if dw < 1.0 && dh < 1.0 && committedSize != .zero {
        return  // swallow sub-pixel jitter
    }
    committedSize = newSize
    super.setFrameSize(newSize)
}
```

**TerminalContainerNSView.ensureTerminal:** Pre-set inset frame before `addSubview`:
```swift
let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
if inset.width > 0 && inset.height > 0 {
    terminal.frame = inset
}
```

## Implementation Strategy

- Implement in order 1→10
- Push to GitHub after each feature
- Each feature is one commit (or small cluster)
- Use parallel subagents for independent work where possible
