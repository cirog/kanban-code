# Lost Features Reimplementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use superpowers:test-driven-development for each task — write failing tests first, then implement.

**Goal:** Reimplement 10 features lost when `/tmp/kanban-code` was cleared before pushing.

**Architecture:** Elm-like unidirectional state (AppState → Action → Reducer → Effect). Pure Swift library (KanbanCodeCore) + SwiftUI app (KanbanCode). All state mutations via `store.dispatch(action)`. macOS 26, Swift 6.2.

**Tech Stack:** SwiftUI, AppKit, SwiftTerm, Swift Testing (`@Test`), SPM

**Repo:** `~/Obsidian/MyVault/Playground/Development/claudeboard`

**Build/Test:** `swift build` / `swift test` from repo root

**Push after each task** to prevent data loss.

---

### Task 1: Todoist Integration — Model + Reducer

**Files:**
- Modify: `Sources/KanbanCodeCore/Domain/Entities/Link.swift`
- Modify: `Sources/KanbanCodeCore/UseCases/BoardStore.swift` (Action, Reducer, Effect enums)
- Modify: `Sources/KanbanCodeCore/UseCases/AssignColumn.swift`
- Test: `Tests/KanbanCodeCoreTests/ReducerTests.swift`

**Step 1: Write failing tests**

Add to `ReducerTests.swift`:

```swift
@Test func todoistSyncCreatesNewCards() {
    var state = AppState()
    let tasks = [TodoistTask(id: "123", content: "Fix bug", description: "Details here")]
    let effects = Reducer.reduce(state: &state, action: .todoistSyncCompleted(tasks))
    #expect(state.links.count == 1)
    let link = state.links.values.first!
    #expect(link.todoistId == "123")
    #expect(link.name == "Fix bug")
    #expect(link.todoistDescription == "Details here")
    #expect(link.source == .todoist)
    #expect(link.column == .backlog)
}

@Test func todoistSyncMatchesExistingByTodoistId() {
    var state = AppState()
    var existing = Link(name: "Fix bug", column: .backlog, source: .todoist)
    existing.todoistId = "123"
    state.links[existing.id] = existing
    let tasks = [TodoistTask(id: "123", content: "Fix bug updated", description: "New details")]
    let _ = Reducer.reduce(state: &state, action: .todoistSyncCompleted(tasks))
    #expect(state.links.count == 1)
    #expect(state.links.values.first!.name == "Fix bug updated")
}

@Test func todoistSyncArchivesMissingTasks() {
    var state = AppState()
    var existing = Link(name: "Old task", column: .backlog, source: .todoist)
    existing.todoistId = "999"
    state.links[existing.id] = existing
    let tasks: [TodoistTask] = [] // task no longer in Todoist
    let _ = Reducer.reduce(state: &state, action: .todoistSyncCompleted(tasks))
    #expect(state.links.values.first!.column == .done)
}

@Test func completeTodoistTaskProducesEffect() {
    var state = AppState()
    var link = Link(name: "Task", column: .backlog, source: .todoist)
    link.todoistId = "456"
    state.links[link.id] = link
    let effects = Reducer.reduce(state: &state, action: .archiveCard(cardId: link.id))
    #expect(effects.contains { if case .completeTodoistTask = $0 { true } else { false } })
}

@Test func assignColumnPreservesTodoist() {
    var link = Link(source: .todoist)
    link.todoistId = "123"
    link.column = .backlog
    let col = AssignColumn.assign(link: link, activityState: nil)
    #expect(col == .backlog)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ReducerTests`
Expected: FAIL — `TodoistTask` type doesn't exist, `.todoist` case missing, etc.

**Step 3: Implement model changes**

In `Link.swift`:
- Add `todoistId: String?` and `todoistDescription: String?` properties
- Add `.todoist` case to `LinkSource` enum
- Add `notes: String?` property (needed for Task 5 too — do it now for one Link change)
- Add `projectId: String?` property (needed for Task 2 — do it now)
- Update `CodingKeys`, `init(from:)`, `encode(to:)`, `init()` for all new fields

Create `Sources/KanbanCodeCore/Domain/Entities/TodoistTask.swift`:
```swift
import Foundation

/// A task fetched from Todoist's API.
public struct TodoistTask: Sendable {
    public let id: String
    public let content: String
    public let description: String?

    public init(id: String, content: String, description: String? = nil) {
        self.id = id
        self.content = content
        self.description = description
    }
}
```

In `BoardStore.swift`:
- Add `Action.todoistSyncCompleted([TodoistTask])` case
- Add `Effect.completeTodoistTask(todoistId: String)` case
- Add reducer logic: match by `todoistId`, create new links for unmatched, archive links whose `todoistId` is no longer in the list
- In `.archiveCard` reducer: if `link.todoistId != nil`, emit `.completeTodoistTask(todoistId:)`

In `AssignColumn.swift`:
- Add early return for `.todoist` source with no session: `return .backlog` (same as `.manual`)

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ReducerTests`
Expected: PASS

**Step 5: Commit and push**

```bash
git add -A && git commit -m "feat: Todoist integration model, reducer, and assignment logic"
git push
```

---

### Task 2: Todoist Integration — Sync Service + Orchestrator

**Files:**
- Create: `Sources/KanbanCodeCore/Infrastructure/TodoistSyncService.swift`
- Modify: `Sources/KanbanCodeCore/UseCases/BackgroundOrchestrator.swift`
- Modify: `Sources/KanbanCodeCore/UseCases/EffectHandler.swift` (handle `.completeTodoistTask`)
- Test: `Tests/KanbanCodeCoreTests/TodoistSyncTests.swift`

**Step 1: Write failing test**

Create `Tests/KanbanCodeCoreTests/TodoistSyncTests.swift`:

```swift
import Testing
@testable import KanbanCodeCore

@Test func parseTodoistJsonOutput() throws {
    let json = """
    [{"id":"123","content":"Fix bug","description":"Some details","labels":["claude"],"priority":1}]
    """
    let tasks = try TodoistSyncService.parseTasks(from: json)
    #expect(tasks.count == 1)
    #expect(tasks[0].id == "123")
    #expect(tasks[0].content == "Fix bug")
    #expect(tasks[0].description == "Some details")
}

@Test func parseTodoistEmptyOutput() throws {
    let tasks = try TodoistSyncService.parseTasks(from: "[]")
    #expect(tasks.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter TodoistSync`
Expected: FAIL — `TodoistSyncService` doesn't exist

**Step 3: Implement**

Create `Sources/KanbanCodeCore/Infrastructure/TodoistSyncService.swift`:

```swift
import Foundation

/// Polls Todoist for tasks with the @claude label and syncs them to the board.
public actor TodoistSyncService {
    private var timer: Task<Void, Never>?
    private var dispatch: (@MainActor @Sendable (Action) -> Void)?

    public init() {}

    public func setDispatch(_ dispatch: @MainActor @Sendable @escaping (Action) -> Void) {
        self.dispatch = dispatch
    }

    public func start() {
        timer = Task {
            await fetchAndSync()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300)) // 5 minutes
                await fetchAndSync()
            }
        }
    }

    public func stop() {
        timer?.cancel()
    }

    private func fetchAndSync() async {
        do {
            let output = try await ShellCommand.run("todoist", arguments: ["task", "list", "--label", "claude", "--format", "json"])
            let tasks = try Self.parseTasks(from: output)
            if let dispatch {
                await dispatch(.todoistSyncCompleted(tasks))
            }
        } catch {
            KanbanCodeLog.warn("todoist", "Sync failed: \(error)")
        }
    }

    /// Parse JSON output from `todoist task list --format json`.
    public static func parseTasks(from json: String) throws -> [TodoistTask] {
        guard let data = json.data(using: .utf8) else { return [] }
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let content = item["content"] as? String else { return nil }
            let description = item["description"] as? String
            return TodoistTask(id: id, content: content, description: description)
        }
    }
}
```

In `BackgroundOrchestrator.swift`:
- Add `private let todoistSync: TodoistSyncService?` property
- Add to `init()` parameter with default `nil`
- In `start()`: call `todoistSync?.start()` after the main loop starts
- In `stop()`: call `todoistSync?.stop()`
- Wire `setDispatch` through

In `EffectHandler.swift`:
- Add `case .completeTodoistTask(let todoistId)`: run `ShellCommand.run("todoist", arguments: ["task", "complete", "--ids", todoistId])`

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TodoistSync`
Expected: PASS

**Step 5: Commit and push**

```bash
git add -A && git commit -m "feat: TodoistSyncService actor with 5min polling + effect handler"
git push
```

---

### Task 3: Todoist Integration — UI (CardView + CardDetailView)

**Files:**
- Modify: `Sources/KanbanCode/CardView.swift` (checkmark icon for Todoist cards)
- Modify: `Sources/KanbanCode/CardDetailView.swift` (`.description` tab)
- Modify: `Sources/KanbanCode/ContentView.swift` (wire TodoistSyncService into orchestrator)

**Step 1: No unit test needed** — this is pure UI. Verify visually.

**Step 2: Implement CardView changes**

In `CardView.swift`, in the bottom HStack after `CardBadgesRow`:
```swift
if card.link.todoistId != nil {
    Image(systemName: "checkmark.circle")
        .font(.app(.caption))
        .foregroundStyle(.secondary)
}
```

**Step 3: Implement CardDetailView `.description` tab**

In `CardDetailView.swift`:
- Add `.description` case to `DetailTab` enum
- Show tab when `card.link.todoistDescription != nil`:
  ```swift
  if card.link.todoistDescription != nil {
      Text("Description").tag(DetailTab.description)
  }
  ```
- Add `descriptionTabView`:
  ```swift
  @ViewBuilder
  private var descriptionTabView: some View {
      if let desc = card.link.todoistDescription {
          ScrollView {
              Text(desc)
                  .font(.app(.body))
                  .textSelection(.enabled)
                  .padding()
                  .frame(maxWidth: .infinity, alignment: .leading)
          }
      }
  }
  ```

**Step 4: Wire in ContentView**

In `ContentView.init()`:
- Create `TodoistSyncService()` and pass to `BackgroundOrchestrator`
- Set dispatch on the sync service

**Step 5: Build and verify**

Run: `swift build`
Expected: Compiles cleanly

**Step 6: Commit and push**

```bash
git add -A && git commit -m "feat: Todoist UI — checkmark icon on cards + description tab"
git push
```

---

### Task 4: Projects as Labels — Model + Reducer

**Files:**
- Create: `Sources/KanbanCodeCore/Domain/Entities/ProjectLabel.swift`
- Modify: `Sources/KanbanCodeCore/UseCases/BoardStore.swift` (new actions, remove old project filtering)
- Modify: `Sources/KanbanCodeCore/Infrastructure/SettingsStore.swift` (add `projectLabels`)
- Remove: `Sources/KanbanCodeCore/UseCases/ProjectDiscovery.swift`
- Test: `Tests/KanbanCodeCoreTests/ReducerTests.swift`

**Step 1: Write failing tests**

```swift
@Test func setProjectOnCard() {
    var state = AppState()
    let label = ProjectLabel(id: KSUID.generate(prefix: "proj"), name: "ClaudeBoard", color: "#FF6600")
    state.projectLabels = [label]
    let link = Link(name: "Task")
    state.links[link.id] = link
    let effects = Reducer.reduce(state: &state, action: .setProject(cardId: link.id, projectId: label.id))
    #expect(state.links[link.id]!.projectId == label.id)
    #expect(!effects.isEmpty) // should persist
}

@Test func clearProjectOnCard() {
    var state = AppState()
    var link = Link(name: "Task")
    link.projectId = "some-id"
    state.links[link.id] = link
    let _ = Reducer.reduce(state: &state, action: .setProject(cardId: link.id, projectId: nil))
    #expect(state.links[link.id]!.projectId == nil)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ReducerTests`
Expected: FAIL — `ProjectLabel` doesn't exist, `.setProject` action missing

**Step 3: Implement**

Create `Sources/KanbanCodeCore/Domain/Entities/ProjectLabel.swift`:
```swift
import Foundation

/// A lightweight label for categorizing cards (replaces path-based Project).
public struct ProjectLabel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var color: String  // hex, e.g. "#FF6600"
    public var description: String?

    public init(id: String = KSUID.generate(prefix: "proj"), name: String, color: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.description = description
    }
}
```

In `BoardStore.swift`:
- Add `projectLabels: [ProjectLabel]` to `AppState`
- Add `Action.setProject(cardId: String, projectId: String?)`
- Add `Action.settingsLoaded` to also accept `projectLabels: [ProjectLabel]`
- Reducer: set `link.projectId = projectId`, persist
- Remove `selectedProjectPath`, `excludedPaths`, `configuredProjects`, `discoveredProjectPaths` from AppState
- Remove `cardMatchesProjectFilter`, `isExcludedFromGlobalView`
- Simplify `filteredCards` to just return `cards`
- Remove `.moveCardToProject`, `.moveCardToFolder`, `.setSelectedProject` actions
- Remove `ProjectDiscovery` references

In `SettingsStore.swift`:
- Add `projectLabels: [ProjectLabel]` to `Settings` struct with backward-compatible decode

Delete `ProjectDiscovery.swift` if it exists.

**Step 4: Run tests and build**

Run: `swift test`
Expected: PASS (fix any compile errors from removed references first)

**Step 5: Commit and push**

```bash
git add -A && git commit -m "feat: ProjectLabel model replacing path-based projects"
git push
```

---

### Task 5: Projects as Labels — UI

**Files:**
- Modify: `Sources/KanbanCode/CardView.swift` (color accent from label)
- Modify: `Sources/KanbanCode/CardDetailView.swift` (remove project move actions)
- Modify: `Sources/KanbanCode/ContentView.swift` (toolbar dropdown, context menu, settings wiring)
- Modify: `Sources/KanbanCode/SettingsView.swift` (label CRUD with color picker)

**Step 1: Implement CardView color accent**

Replace `projectColorMap` environment with a lookup from `projectLabels`:
```swift
@Environment(\.projectLabels) private var projectLabels

private var projectColorHex: String {
    if let pid = card.link.projectId,
       let label = projectLabels.first(where: { $0.id == pid }) {
        return label.color
    }
    return "#808080"
}
```

**Step 2: Context menu — "Set Project" submenu**

In CardView's context menu:
```swift
Menu("Set Project") {
    Button("None") { onSetProject(nil) }
    Divider()
    ForEach(projectLabels) { label in
        Button {
            onSetProject(label.id)
        } label: {
            HStack {
                Circle().fill(Color(hex: label.color)).frame(width: 8, height: 8)
                Text(label.name)
            }
        }
    }
}
```

Add `onSetProject: (String?) -> Void` callback.

**Step 3: Toolbar dropdown**

In ContentView toolbar, add a `Menu` with color dots for each label + "New Project..." that opens a sheet.

**Step 4: SettingsView label management**

Add a section to SettingsView with:
- List of labels with color circle + name
- Add/Edit/Delete buttons
- Color picker grid (predefined hex colors)
- Save to settings via `SettingsStore`

**Step 5: Build and verify**

Run: `swift build`
Expected: Compiles cleanly

**Step 6: Commit and push**

```bash
git add -A && git commit -m "feat: Projects as Labels UI — context menu, toolbar dropdown, settings"
git push
```

---

### Task 6: Usage Bar Pace Coloring

**Files:**
- Modify: `Sources/KanbanCode/ContentView.swift` (usage bar color logic)
- Test: inline in ContentView or extract helper

**Step 1: Write test**

```swift
@Test func paceRatioCalculation() {
    // 50% used, 50% elapsed → ratio 1.0 → orange
    #expect(UsagePaceColor.color(utilization: 50, elapsedFraction: 0.5) == .orange)
    // 30% used, 50% elapsed → ratio 0.6 → green
    #expect(UsagePaceColor.color(utilization: 30, elapsedFraction: 0.5) == .green)
    // 80% used, 50% elapsed → ratio 1.6 → red
    #expect(UsagePaceColor.color(utilization: 80, elapsedFraction: 0.5) == .red)
}
```

**Step 2: Implement**

Create `Sources/KanbanCodeCore/Infrastructure/UsagePaceColor.swift`:
```swift
import Foundation

public enum UsagePaceColor: Sendable {
    case green, orange, red

    /// Calculate pace color from current utilization and time elapsed in the window.
    /// - utilization: 0-100 percentage used
    /// - elapsedFraction: 0.0-1.0 how far through the time window
    public static func color(utilization: Double, elapsedFraction: Double) -> UsagePaceColor {
        guard elapsedFraction > 0.01 else { return .green } // just started
        let expectedUtilization = elapsedFraction * 100.0
        let ratio = utilization / expectedUtilization
        if ratio >= 1.0 { return .red }
        if ratio >= 0.8 { return .orange }
        return .green
    }
}
```

In ContentView toolbar usage bars, calculate `elapsedFraction` from `resetsAt` dates and apply color:
```swift
let elapsed5h = usageData.fiveHourResetsAt.map { 1.0 - $0.timeIntervalSinceNow / (5 * 3600) } ?? 0
let color5h = UsagePaceColor.color(utilization: usageData.fiveHourUtilization, elapsedFraction: max(0, min(1, elapsed5h)))
```

Map to SwiftUI `Color`: `.green`, `.orange`, `.red`.

**Step 3: Run tests**

Run: `swift test --filter paceRatio`
Expected: PASS

**Step 4: Commit and push**

```bash
git add -A && git commit -m "feat: usage bar pace coloring (green/orange/red)"
git push
```

---

### Task 7: Compact Cards

**Files:**
- Modify: `Sources/KanbanCode/CardView.swift`

**Step 1: No test needed** — pure cosmetic

**Step 2: Implement**

In `CardView.swift` body:
- Remove the "Project + branch + link icons" HStack (the one with `if let projectName`)
- Remove `CardBadgesRow(card: card)` from the bottom row
- Keep: title, activity icon/badge, relative time, project color accent

The card body becomes:
```swift
VStack(alignment: .leading, spacing: 6) {
    Text(card.displayTitle)
        .font(.app(.body, weight: .medium))
        .lineLimit(2)
        .foregroundStyle(.primary)

    HStack(spacing: 6) {
        if card.link.cardLabel == .session {
            AssistantIcon(assistant: card.link.effectiveAssistant)
                .frame(width: CGFloat(14).scaled, height: CGFloat(14).scaled)
                .foregroundStyle(Color.primary.opacity(0.4))
        } else {
            CardLabelBadge(label: card.link.cardLabel)
        }

        if card.link.todoistId != nil {
            Image(systemName: "checkmark.circle")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }

        Text(card.relativeTime)
            .font(.app(.caption2))
            .foregroundStyle(.tertiary)

        Spacer()
    }
}
```

**Step 3: Build**

Run: `swift build`
Expected: Compiles

**Step 4: Commit and push**

```bash
git add -A && git commit -m "feat: compact cards — title + icon + time only"
git push
```

---

### Task 8: Card Note Pad

**Files:**
- Modify: `Sources/KanbanCode/ContentView.swift` (note pad below board)
- Modify: `Sources/KanbanCodeCore/UseCases/BoardStore.swift` (new action)
- Test: `Tests/KanbanCodeCoreTests/ReducerTests.swift`

**Step 1: Write failing test**

```swift
@Test func updateNotes() {
    var state = AppState()
    let link = Link(name: "Task")
    state.links[link.id] = link
    let effects = Reducer.reduce(state: &state, action: .updateNotes(cardId: link.id, notes: "My notes"))
    #expect(state.links[link.id]!.notes == "My notes")
    #expect(!effects.isEmpty)
}
```

**Step 2: Run test to verify failure**

Run: `swift test --filter updateNotes`
Expected: FAIL

**Step 3: Implement reducer**

In `BoardStore.swift`:
- Add `Action.updateNotes(cardId: String, notes: String?)`
- Reducer: `link.notes = notes`, persist

**Step 4: Implement UI**

In `ContentView.swift`, below the board `HStack`, when a card is selected:
```swift
if let selectedId = store.state.selectedCardId,
   let link = store.state.links[selectedId] {
    VStack(spacing: 4) {
        HStack {
            Text("Notes")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.notes ?? "", forType: .string)
            }
            .buttonStyle(.plain)
            .font(.app(.caption))
            Button("Push to Terminal") {
                if let tmux = link.tmuxLink?.sessionName, let notes = link.notes, !notes.isEmpty {
                    Task {
                        try? await ShellCommand.run("tmux", arguments: ["send-keys", "-t", tmux, notes, "Enter"])
                        store.dispatch(.updateNotes(cardId: selectedId, notes: nil))
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.app(.caption))
        }
        TextEditor(text: Binding(
            get: { link.notes ?? "" },
            set: { store.dispatch(.updateNotes(cardId: selectedId, notes: $0.isEmpty ? nil : $0)) }
        ))
        .font(.app(.body, design: .monospaced))
        .frame(maxHeight: 500)
    }
    .padding(.horizontal)
}
```

**Step 5: Run tests**

Run: `swift test --filter updateNotes`
Expected: PASS

**Step 6: Commit and push**

```bash
git add -A && git commit -m "feat: card note pad with copy + push-to-terminal"
git push
```

---

### Task 9: Summary Tab

**Files:**
- Modify: `Sources/KanbanCode/CardDetailView.swift`

**Step 1: No unit test** — involves shell execution + UI

**Step 2: Implement**

In `CardDetailView.swift`:
- Add `.summary` to `DetailTab` enum
- Add state vars:
  ```swift
  @State private var summaryText: String?
  @State private var isLoadingSummary = false
  @State private var summaryCardId: String?
  ```
- Show tab when `card.link.sessionLink != nil`:
  ```swift
  if card.link.sessionLink != nil {
      Text("Summary").tag(DetailTab.summary)
  }
  ```
- Add `summaryTabView`:
  ```swift
  @ViewBuilder
  private var summaryTabView: some View {
      VStack {
          if isLoadingSummary {
              ProgressView("Generating summary...")
          } else if let summary = summaryText {
              ScrollView {
                  Text(summary)
                      .font(.app(.body))
                      .textSelection(.enabled)
                      .padding()
                      .frame(maxWidth: .infinity, alignment: .leading)
              }
          } else {
              Button("Generate Summary") { loadSummary() }
                  .padding()
          }
      }
  }
  ```
- `loadSummary()`: read last 10 turns via `TranscriptReader.readTail`, build prompt, run `claude -p --model sonnet`, set `summaryText`

**Step 3: Build**

Run: `swift build`
Expected: Compiles

**Step 4: Commit and push**

```bash
git add -A && git commit -m "feat: summary tab — claude-generated session summary"
git push
```

---

### Task 10: App Icon

**Files:**
- Modify: `Sources/KanbanCode/App.swift`

**Step 1: Implement**

The app icon is already handled via `AppIcon.icns` in the bundle. For the runtime override using `logo.png`:

In `App.swift` `applicationDidFinishLaunching`, after the existing icon code, add a fallback to logo.png:
```swift
// Fallback: set from logo.png in assets (for development builds without .icns)
if NSApp.applicationIconImage == nil || NSApp.applicationIconImage?.size == .zero {
    let logoPath = Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("logo.png") }
    if let path = logoPath, let image = NSImage(contentsOfFile: path) {
        NSApp.applicationIconImage = image
    }
}
```

Actually, looking at the existing code, it already sets icon from `AppIcon.icns` bundled resource. The `logo.png` is just the source asset. This task is already done.

**Step 2: Commit and push** (skip if no changes needed)

---

### Task 11: Prompt Timeline Tab

**Files:**
- Modify: `Sources/KanbanCodeCore/Adapters/ClaudeCode/JsonlParser.swift` (add `parseLocalCommandArgs`)
- Modify: `Sources/KanbanCodeCore/Adapters/ClaudeCode/TranscriptReader.swift` (append args to slash commands)
- Modify: `Sources/KanbanCode/CardDetailView.swift` (replace prompt editor with timeline)
- Test: `Tests/KanbanCodeCoreTests/JsonlParserTests.swift`
- Test: `Tests/KanbanCodeCoreTests/TranscriptReaderTests.swift`

**Step 1: Write failing tests**

In `JsonlParserTests.swift`:
```swift
@Test func parseLocalCommandArgs() {
    let text = "<command-name>/brainstorming</command-name><command-args>build a feature</command-args>"
    let args = JsonlParser.parseLocalCommandArgs(text)
    #expect(args == "build a feature")
}

@Test func parseLocalCommandArgsNone() {
    let text = "<command-name>/clear</command-name>"
    let args = JsonlParser.parseLocalCommandArgs(text)
    #expect(args == nil)
}
```

In `TranscriptReaderTests.swift`:
```swift
@Test func slashCommandIncludesArgs() {
    let obj: [String: Any] = [
        "type": "user",
        "message": ["content": "<command-name>/brainstorming</command-name><command-args>plan a widget</command-args>"],
        "timestamp": "2026-03-16T10:00:00Z"
    ]
    let blocks = TranscriptReader.extractUserBlocks(from: obj)
    #expect(blocks.count == 1)
    #expect(blocks[0].text == "/brainstorming plan a widget")
}
```

**Step 2: Run tests**

Run: `swift test --filter parseLocalCommandArgs && swift test --filter slashCommandIncludesArgs`
Expected: FAIL

**Step 3: Implement JsonlParser.parseLocalCommandArgs**

In `JsonlParser.swift`:
```swift
/// Extract args from `<command-args>text</command-args>`.
public static func parseLocalCommandArgs(_ text: String) -> String? {
    let regex = try! Regex("<command-args>([\\s\\S]*?)</command-args>")
    guard let match = text.firstMatch(of: regex) else { return nil }
    let args = String(match.output[1].substring!)
    return args.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

**Step 4: Update TranscriptReader.extractUserBlocks**

In the slash command branch:
```swift
if let command = JsonlParser.parseLocalCommand(text) {
    if let args = JsonlParser.parseLocalCommandArgs(text), !args.isEmpty {
        return [ContentBlock(kind: .text, text: "\(command) \(args)")]
    }
    return [ContentBlock(kind: .text, text: command)]
}
```

**Step 5: Implement prompt timeline UI in CardDetailView**

Replace the prompt editor tab body with a timeline view:
- Add state:
  ```swift
  @State private var promptTurns: [ConversationTurn] = []
  @State private var isLoadingPrompts = false
  @State private var promptsCardId: String?
  ```
- Show Prompts tab when `card.link.promptBody != nil || card.link.sessionLink != nil`
- `loadPrompts()`: stream all turns, filter `role == "user"` and `!textPreview.hasPrefix("[tool result")`
- `promptTabView`: header with count + copy button, original prompt section (if `promptBody != nil`), then `ForEach` list with timestamp + text preview
- Timestamp formatting: `formatPromptTimestamp(_:)` — parse ISO8601, same-day = "HH:mm", other = "MMM dd, HH:mm"

**Step 6: Run tests**

Run: `swift test --filter JsonlParser && swift test --filter TranscriptReader`
Expected: PASS

**Step 7: Commit and push**

```bash
git add -A && git commit -m "feat: prompt timeline tab with chronological user prompts"
git push
```

---

### Task 12: Terminal Jitter Fix

**Files:**
- Modify: `Sources/KanbanCode/TerminalRepresentable.swift`

**Step 1: No unit test** — AppKit frame behavior, verify visually

**Step 2: Implement setFrameSize guard on BatchedTerminalView**

Add to `BatchedTerminalView`:
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

**Step 3: Pre-set inset frame in ensureTerminal**

In `TerminalContainerNSView.ensureTerminal`, before `addSubview(terminal)`:
```swift
let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
if inset.width > 0 && inset.height > 0 {
    terminal.frame = inset
}
```

**Step 4: Build**

Run: `swift build`
Expected: Compiles

**Step 5: Commit and push**

```bash
git add -A && git commit -m "fix: terminal jitter — 1px threshold on setFrameSize + pre-set inset frame"
git push
```

---

## Execution Summary

| Task | Feature | Type | Files |
|------|---------|------|-------|
| 1 | Todoist — Model + Reducer | Core | 4 files |
| 2 | Todoist — Sync Service | Core | 3 files + 1 new |
| 3 | Todoist — UI | UI | 3 files |
| 4 | Projects as Labels — Model | Core | 3 files + 1 new |
| 5 | Projects as Labels — UI | UI | 4 files |
| 6 | Usage Pace Coloring | Core+UI | 2 files |
| 7 | Compact Cards | UI | 1 file |
| 8 | Card Note Pad | Core+UI | 2 files |
| 9 | Summary Tab | UI | 1 file |
| 10 | App Icon | — | Already done |
| 11 | Prompt Timeline | Core+UI | 3 files |
| 12 | Terminal Jitter Fix | AppKit | 1 file |

Total: 12 tasks, ~20 files touched, push after each.
