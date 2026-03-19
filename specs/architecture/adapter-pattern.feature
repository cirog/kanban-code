Feature: Adapter Pattern and Clean Architecture
  As a developer building for extensibility
  I want the system to use adapters for AI CLI integration
  So that we could potentially support Gemini CLI or others in the future

  Background:
    Given the Kanban Code application architecture follows clean architecture principles

  # ── Core Domain (no external dependencies) ──

  Scenario: Domain entities are framework-agnostic
    Then the following domain entities should exist independently of any AI CLI:
      | Entity             | Fields                                              |
      | Kanban CodeCard         | id, title, description, column, project, timestamps  |
      | Session            | id, metadata, activityState, links                   |
      | Worktree           | path, branch, repoRoot                               |
      | TmuxSession        | name, path, attached                                 |
      | PullRequest        | number, title, state, reviewStatus, checksStatus      |
      | Project            | path, name, repoRoot, settings                       |
      | Link               | sessionId, worktreePath, tmuxSession, prNumber        |

  Scenario: Use cases don't depend on AI CLI specifics
    Then the following use cases should work through port interfaces:
      | Use Case              | Port Interface            |
      | StartSession          | SessionLauncher           |
      | ResumeSession         | SessionLauncher           |
      | ForkSession           | SessionStore              |
      | CheckpointSession     | SessionStore              |
      | DiscoverSessions      | SessionDiscovery          |
      | DetectActivity        | ActivityDetector          |
      | FetchPRStatus         | PRTracker                 |
      | SendNotification      | Notifier                  |
      | ManageWorktrees       | WorktreeManager           |

  # ── Claude Code Adapter ──

  Scenario: Claude Code adapter implements all ports
    Then a ClaudeCode adapter should implement:
      | Port              | Implementation                                  |
      | SessionLauncher   | `claude --resume`, `claude --worktree`           |
      | SessionStore      | .jsonl file read/write/fork/truncate             |
      | SessionDiscovery  | ~/.claude/projects/ scanning                     |
      | ActivityDetector  | Hooks + .jsonl mtime polling                     |
      | HookManager       | ~/.claude/settings.json hook configuration       |

  Scenario: Session file format is abstracted
    Given the SessionStore port defines:
      | Method                  | Description                          |
      | readSession(id)         | Read session metadata                |
      | readTranscript(id)      | Read conversation turns              |
      | forkSession(id)         | Duplicate session with new ID        |
      | truncateSession(id, n)  | Truncate to turn N with backup       |
      | searchSessions(query)   | Full-text search across sessions     |
    Then the Claude adapter implements these using .jsonl files
    And a hypothetical Gemini adapter would use its own format

  Scenario: Launch command is abstracted
    Given the SessionLauncher port defines:
      | Method                         | Description                     |
      | launch(project, prompt, opts)  | Start a new session             |
      | resume(sessionId, opts)        | Resume an existing session      |
    Then the Claude adapter uses `claude --worktree` and `claude --resume`
    And opts includes: worktreeName, shellOverride, dangerouslySkipPermissions

  Scenario: Hook system is abstracted
    Given the HookManager port defines:
      | Method                    | Description                     |
      | detectHooks()             | Check which hooks are installed |
      | installHooks()            | Set up required hooks           |
      | handleHookEvent(event)    | Process incoming hook data      |
    Then the Claude adapter reads/writes ~/.claude/settings.json
    And hook events are normalized to generic types:
      | Generic Event       | Claude Hook          |
      | session_start       | SessionStart         |
      | session_end         | SessionEnd           |
      | user_prompt         | UserPromptSubmit     |
      | ai_stopped          | Stop                 |
      | needs_attention     | Notification         |

  # ── Shared Infrastructure (adapter-independent) ──

  Scenario: These components are shared across all adapters
    Then the following should NOT depend on any specific AI CLI:
      | Component          | Responsibility                         |
      | TmuxManager        | Create/attach/kill tmux sessions       |
      | WorktreeManager    | git worktree list/add/remove           |
      | PRTracker          | gh CLI for PR status (adapter for Git) |
      | Notifier           | Pushover + macOS notifications         |
      | SyncManager        | Mutagen sync lifecycle                 |
      | RemoteShell        | SSH command routing                    |
      | SearchEngine       | BM25 scoring engine                    |
      | CoordinationStore  | links.db read/write (SQLite)            |

  # ── Code Organization ──

  Scenario: Project structure follows clean architecture
    Then the source code should be organized as:
      | Directory               | Contents                              |
      | domain/entities/        | Pure domain types and logic           |
      | domain/ports/           | Port interfaces (protocols/traits)    |
      | usecases/               | Application use cases                 |
      | adapters/claude-code/   | Claude Code-specific implementations  |
      | adapters/git/           | Git/GitHub operations                 |
      | adapters/tmux/          | tmux operations                       |
      | adapters/notifications/ | Pushover, macOS notifications         |
      | adapters/remote/        | SSH, Mutagen                          |
      | infrastructure/         | Coordination file, settings, cache    |
      | ui/                     | Native UI components                  |

  Scenario: Dependency rule
    Then domain/ should have zero external imports
    And usecases/ should only import from domain/
    And adapters/ should implement domain/ports/ interfaces
    And ui/ should depend on usecases/ not adapters/
