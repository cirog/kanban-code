# Kanban — Specs

BDD specifications for a native macOS liquid glass Kanban board to control Claude Code.

## Spec Structure

```
specs/
├── board/                         # Kanban board layout and interaction
│   ├── kanban-columns.feature     # Column definitions, card rendering, responsive layout
│   ├── card-lifecycle.feature     # Automated card movement between columns
│   └── drag-and-drop.feature     # Manual card reordering and column moves
│
├── sources/                       # Where backlog items come from
│   ├── github-issues.feature     # GitHub issue import via gh CLI
│   └── manual-tasks.feature      # Manual task creation and management
│
├── sessions/                      # Claude Code session management
│   ├── discovery.feature         # Session discovery from ~/.claude/projects/
│   ├── launching.feature         # Starting Claude with worktree and tmux
│   ├── linking.feature           # Session ↔ worktree ↔ tmux ↔ PR linking
│   ├── activity-detection.feature # Detecting active/idle/needs-attention
│   ├── operations.feature        # Fork, checkpoint, rename
│   ├── search.feature            # BM25 full-text search across sessions
│   └── archive.feature           # All Sessions column and session revival
│
├── terminal/                      # Terminal and session history
│   ├── embedded-terminal.feature # Native terminal emulator in card detail
│   └── session-history.feature   # Conversation transcript view
│
├── review/                        # PR and code review tracking
│   ├── pr-tracking.feature       # PR discovery, status badges, CI checks
│   └── review-actions.feature    # Addressing review comments, merge detection
│
├── notifications/                 # Notifications and onboarding
│   ├── push-notifications.feature # Pushover + macOS notifications, dedup
│   └── hook-onboarding.feature   # Automatic Claude hook setup
│
├── remote/                        # Remote execution support
│   ├── mutagen-sync.feature      # Mutagen file sync management
│   └── remote-execution.feature  # Shell interception, path replacement, fallback
│
├── system/                        # System integration
│   ├── system-tray.feature       # Menu bar app, Amphetamine integration
│   ├── settings.feature          # Settings file, progressive enhancement
│   └── projects.feature          # Multi-project, global view, exclusions
│
├── ui/                            # UI design and performance
│   ├── liquid-glass.feature      # Apple liquid glass design, native interactions
│   └── performance.feature       # Virtualization, caching, startup speed
│
└── architecture/                  # Technical architecture
    ├── adapter-pattern.feature   # Clean architecture, port/adapter pattern
    ├── coordination-file.feature # links.json structure and operations
    └── technology-decision.feature # Swift/SwiftUI decision and rationale
```

## Key Learnings Applied

| Source Project     | Learnings Used                                                    |
|--------------------|-------------------------------------------------------------------|
| claude-resume      | Session discovery, .jsonl parsing, BM25 search, fork, checkpoint  |
| claude-remote      | Fake shell, path replacement, Mutagen sync, local fallback        |
| git-orchard        | tmux IPC, worktree management, PR status, session matching        |
| claude-pushover    | Hook system, Pushover API, dedup logic, session numbering         |
| cc-amphetamine     | Secondary app pattern, Amphetamine trigger, Electron tray         |

## License

AGPLv3
