# Claude Code Session Data Model — Theoretical Reference

**Purpose**: This document describes the theoretical data model of Claude Code sessions
as observed from official documentation, GitHub issues, and empirical analysis of session
files. ClaudeBoard's reconciler and session linking logic should conform to this model.
When bugs appear, check observed behavior against this reference to determine if reality
breaks theory (update this doc) or if our implementation diverges from theory (fix the code).

**Last validated**: 2026-03-21

---

## Entity Definitions

### Session (sessionId)

A UUID that identifies a single API context window. One sessionId = one JSONL file.

**New sessionId created on EVERY:**
- Fresh `claude` invocation (new terminal)
- `/clear` command
- `--resume` / `--continue` (confirmed: GitHub issue #12235)
- Compaction overflow (context continuation)
- Subagent spawn (Agent tool)
- `--fork-session`
- Scheduled task execution (`claude --task`)

**Key property**: SessionId is ephemeral. It changes constantly. It should never be used
as an association key for linking sessions to cards.

### Slug

A server-assigned three-word identifier (e.g., `drifting-wishing-kettle`) representing
a **logical conversation** — the conceptual thread of work across time.

**Characteristics:**
- Assigned server-side after the first API round-trip
- Not present at session creation — appears only after first assistant response
- Not included in hook event payloads — can only be obtained by parsing JSONL files
- Present in ~18% of sessions (empirical: 138/757 sessions had slugs)
- Null for: subagents, short-lived sessions, scheduled tasks that error early, sessions
  that don't complete a full API round-trip

**Reliability concerns:**
- Preservation across `--resume` is inconsistent (GitHub reports suggest it sometimes
  changes)
- Scheduled tasks and subagents often get their own slug unrelated to any parent
  conversation
- Server behavior may change without notice

### Project Directory

The encoded working directory path under `~/.claude/projects/`.

Example: `/Users/ciro` → `-Users-ciro`

**Warning**: Project directory is NOT a suitable association key. The home directory
(`/Users/ciro`) is shared by every session launched from `~`, including scheduled tasks,
Claude Desktop, and bare CLI invocations. Using it as a matching key causes unrelated
sessions to collide.

### Tmux Session Name

A terminal session name created by ClaudeBoard when launching a card.

Format: `{projectName}-{cardId}` (e.g., `ciro-card_3BF9q2WRdD7sRlghwkCDAxTbRIz`)

**Characteristics:**
- Not part of Claude Code's data model — external, created by ClaudeBoard
- Available in hook events via `$TMUX` environment variable capture
- Contains the card ID literally — most direct and deterministic link
- Only exists for ClaudeBoard-managed sessions (not Claude Desktop, not bare CLI,
  not scheduled tasks)
- A single tmux session hosts many sequential sessions (/clear, compaction, resume)

### Hook Events

Lifecycle events emitted by Claude Code:

| Event | When | Source field values |
|-------|------|---------------------|
| SessionStart | Session created | `startup`, `resume`, `clear`, `compact` |
| SessionEnd | Session terminates | `reason` field |
| UserPromptSubmit | Before user prompt processed | — |
| Stop | After assistant turn completes | — |
| Notification | Assistant needs attention | — |

Hook input always includes: `session_id`, `transcript_path`, `cwd`, `hook_event_name`.
Hook input does NOT include: `slug`.

---

## Cardinality Relationships

```
  RELATIONSHIP                    CARDINALITY
  ──────────────────────────────  ─────────────
  Project Dir    → Session        1 : N
  Slug           → Session        1 : N
  Session        → JSONL File     1 : 1
  Session        → Hook Events    1 : N
  Tmux Terminal  → Session        1 : N
  Slug           ↔ Tmux Terminal  M : N
```

### Diagram

```
  ┌─────────────────┐           ┌─────────────────┐
  │  PROJECT DIR    │  1:N      │      SLUG       │  1:N
  │  (encoded cwd)  │──────┐    │ (logical convo) │──────┐
  └─────────────────┘      │    └─────────────────┘      │
                           │                              │
                           ▼                              ▼
                 ┌──────────────────────────────────────────┐
                 │              SESSION                      │
                 │           (sessionId = UUID)               │
                 │                                            │
                 │  One UUID = one JSONL file = one context   │
                 └─────────┬──────────────────────┬──────────┘
                           │ 1:1                  │ 1:N
                           ▼                      ▼
                 ┌──────────────┐       ┌──────────────────┐
                 │ SESSION FILE │       │   HOOK EVENT     │
                 │ {uuid}.jsonl │       │  (timestamped)   │
                 └──────────────┘       └──────────────────┘

  ┌─────────────────┐
  │ TMUX TERMINAL   │  1:N
  │ (session name)  │──────→ SESSION (via hook's tmux_session_name)
  └─────────────────┘
```

---

## Association Hierarchy for Card Linking

When determining which card a session belongs to:

```
  1. TMUX NAME (strongest — immediate, deterministic)
     │ • Contains card ID in name format
     │ • Available at SessionStart hook
     │ • If NULL → DO NOT MATCH, fall through
     │
  2. SLUG (deferred — stable when present)
     │ • Cross-terminal resume link
     │ • Available after first API response (parse JSONL)
     │ • If NULL → DO NOT MATCH, fall through
     │
  3. NO MATCH → Create discovered card
     │ • Sessions with no tmux and no matching slug are orphans
     │
  ✘  SESSION ID — NEVER an association key (too ephemeral)
  ✘  PROJECT PATH — NEVER an association key (too broad)
```

**Critical rule**: Null keys NEVER match. A null tmux does not mean "try to match by
project path." A null slug does not mean "match by session proximity." Null means
"no data for this key — fall through to next level or create discovered card."

### Reconciler Merge on New Data

When new data arrives (slug appears in a JSONL file, or a new SessionStart fires):

1. **SessionStart with tmux name containing card ID** → link session to card immediately
2. **Slug appears in session file** → check if any card already has that slug → if yes,
   absorb session into that card
3. **Discovered card and managed card share same slug** → merge discovered into managed
4. **Session has no tmux and no slug match** → remains as discovered card

---

## Empirical Observations (2026-03-21)

### Session Chain Pollution Case Study

Card "CB" (`card_3BF9q2WRdD7sRlghwkCDAxTbRIz`) accumulated 7 sessions, 6 of which were
unrelated scheduled tasks:

| Session | Slug | What it actually was |
|---------|------|---------------------|
| 83597852 | gleaming-brewing-balloon | scheduled-task: daily-prep |
| b9c0bc14 | (null) | scheduled-task: graphiti-maintenance |
| 53f21ed4 | parallel-napping-mitten | scheduled-task: prep-meetings |
| b9fa7fe9 | cryptic-gathering-zephyr | Actual CB work (brainstorming) |
| 2bc53d24 | sorted-kindling-goose | scheduled-task: daily-prep |
| 3f30bf5b | keen-juggling-snail | scheduled-task: daily-prep |
| 9a139878 | atomic-bouncing-candle | scheduled-task: graphiti-cleanup |

**Root cause**: Old heuristic reconciler matched sessions by project path (`/Users/ciro`).
All scheduled tasks run from home directory and collided with the CB card. Context
continuation logic then chained them as "previous sessions." The latest scheduled task
(`9a139878`, graphiti-cleanup) became the card's current session, driving its column
to `in_progress`.

**Lesson**: Project path matching is fundamentally broken for home-directory sessions.
Tmux name (with embedded card ID) is the only reliable immediate association key.

---

## Sources

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [How Claude Code Works](https://code.claude.com/docs/en/how-claude-code-works)
- [Session ID changes when resuming — GitHub Issue #12235](https://github.com/anthropics/claude-code/issues/12235)
- [/clear starts a new session — GitHub Issue #32871](https://github.com/anthropics/claude-code/issues/32871)
- [How Claude Code Session Continuation Works — Jesse Vincent](https://blog.fsck.com/releases/2026/02/22/claude-code-session-continuation/)
- [Claude Code Session Management — Steve Kinney](https://stevekinney.com/courses/ai-development/claude-code-session-management)
- Empirical analysis of 757 session files in `~/.claude/projects/-Users-ciro/` (2026-03-21)
