# Claude Code Session Data Model — Theoretical Reference

**Purpose**: This document describes the theoretical data model of Claude Code sessions
as observed from official documentation, GitHub issues, and empirical analysis of session
files. ClaudeBoard's reconciler and session linking logic should conform to this model.
When bugs appear, check observed behavior against this reference to determine if reality
breaks theory (update this doc) or if our implementation diverges from theory (fix the code).

**Last validated**: 2026-03-21 (full empirical validation against 789 sessions)

---

## Entity Definitions

### Session (sessionId)

A UUID that identifies a single API context window. One sessionId = one JSONL file.

**New sessionId created on EVERY:**
- Fresh `claude` invocation (new terminal)
- `/clear` command
- `--resume` / `--continue` (confirmed: GitHub issue #12235)
- Compaction overflow (context continuation)
- Subagent spawn (Agent tool) — creates a child session that inherits the parent's slug
- `--fork-session`
- Scheduled task execution (`claude --task`)

**Key property**: SessionId is ephemeral. It changes constantly. It should never be used
as an association key for linking sessions to cards.

**Empirical**: 789 unique sessionIds across 789 JSONL files — confirmed 1:1.
Average gap between consecutive sessions: 12 minutes. Median: <1 minute.

### Slug

A server-assigned three-word identifier (e.g., `drifting-wishing-kettle`).

**What slug actually represents**: A server-side conversation identifier that is
**inherited by child sessions** (subagents spawned via the Agent tool). It does NOT
reliably identify a single logical conversation from the user's perspective.

**Characteristics:**
- Assigned server-side after the first API round-trip (confirmed: 129/143 sessions
  had slug appear after the first assistant message)
- **Inherited by subagent sessions**: child sessions receive the parent's slug at
  creation time, before their own first assistant response (14 sessions confirmed)
- Not included in hook event payloads (confirmed: 0/3988 hook events contain slug)
- Can only be obtained by parsing JSONL files
- Present in ~18% of sessions (empirical: 143/789 = 18.1%)
- Preserved across `--resume` / context continuation (confirmed: `rippling-painting-cherny`
  appears in 2 parent sessions that are the same logical conversation continued next day)

**Slug collisions — CRITICAL:**
- 3 out of 128 unique slugs (2.3%) appear across **unrelated conversations**
- All 3 collisions are caused by subagent inheritance: parent session gets slug X,
  spawns N subagents via Agent tool, each child inherits slug X with a different
  sessionId and different JSONL file
- Example: `immutable-finding-mist` appears on 9 sessions (1 parent + 8 subagents)
  covering topics from "move badge to dock" to "fix slug race condition"
- This means: **slug is NOT safe as an association key for card linking**. Using slug
  to match sessions to cards will merge a parent's subagent sessions into the parent's
  card, even though they are independent pieces of work

**When slug is null:**
- Sessions with <10 messages (622/646 no-slug sessions had <10 messages)
- Sessions that never complete a full API round-trip
- Some long interactive sessions also lack slugs (9 sessions with >50 messages had no slug)

### Project Directory

The encoded working directory path under `~/.claude/projects/`.

Example: `/Users/ciro` → `-Users-ciro`

**Warning**: Project directory is NOT a suitable association key. The home directory
(`/Users/ciro`) accounts for 760/789 = **96%** of all sessions, including scheduled tasks,
Claude Desktop, bare CLI invocations, and all ClaudeBoard-managed sessions. Using it as
a matching key causes unrelated sessions to collide.

### Tmux Session Name

A terminal session name created by ClaudeBoard when launching a card.

Format: `{projectName}-{cardId}` (e.g., `ciro-card_3BF9q2WRdD7sRlghwkCDAxTbRIz`)

**Characteristics:**
- Not part of Claude Code's data model — external, created by ClaudeBoard
- Available in hook events as `tmuxSession` field (only when session launched inside tmux)
- Contains the card ID literally — most direct and deterministic link
- Only present in **3.9%** of SessionStart hook events (31/805). The other 96.1% are
  non-ClaudeBoard sessions (CLI, Desktop, scheduled tasks, subagents)
- A single tmux session hosts many sequential sessions (/clear, compaction, resume).
  Confirmed: 4 tmux names had multiple SessionStart events (up to 7 sessions per tmux)
- External tmux sessions (not created by ClaudeBoard) also exist: `claude-XXXXXXXX`
  format (2 observed). These do NOT contain card IDs.

### Hook Events

Lifecycle events emitted by Claude Code:

| Event | When | Source field values |
|-------|------|---------------------|
| SessionStart | Session created | `startup`, `resume`, `clear`, `compact` |
| SessionEnd | Session terminates | `reason` field |
| UserPromptSubmit | Before user prompt processed | — |
| Stop | After assistant turn completes | — |
| Notification | Assistant needs attention | — |

Hook event fields (empirical, from 3988 events):
- Always present: `sessionId`, `event`, `timestamp`, `transcriptPath`
- Sometimes present: `tmuxSession` (only when launched inside tmux — 3.9% of SessionStart)
- Never present: `slug`, `cwd`

**Note**: The previous version of this document stated hook input includes `cwd` and
`hook_event_name`. Empirical analysis of 3988 hook events found neither field present.
This may be version-dependent or the hook.sh script may transform input before writing.

---

## Cardinality Relationships

```
  RELATIONSHIP                    CARDINALITY    NOTES
  ──────────────────────────────  ─────────────  ─────────────────────────────
  Project Dir    → Session        1 : N          96% share /Users/ciro
  Slug           → Session        1 : N*         *includes inherited children
  Session        → JSONL File     1 : 1          confirmed (789/789)
  Session        → Hook Events    1 : N          confirmed
  Tmux Terminal  → Session        1 : N          confirmed (up to 7)
  Slug           ↔ Tmux Terminal  M : N          subagent children lack tmux
```

### Slug Inheritance Diagram

```
  PARENT SESSION (has tmux, gets slug from server)
  │
  ├── slug = "immutable-finding-mist"
  │   tmuxSession = "ciro-card_3BF9q..."
  │   title = (untitled)
  │
  ├── SUBAGENT 1 (Agent tool spawn)
  │   slug = "immutable-finding-mist"    ← INHERITED from parent
  │   tmuxSession = (null)               ← subagents have no tmux
  │   title = "fix-task-notification-rendering"
  │
  ├── SUBAGENT 2 (Agent tool spawn)
  │   slug = "immutable-finding-mist"    ← INHERITED
  │   tmuxSession = (null)
  │   title = "dead-code-cleanup"
  │
  └── ... (up to 8 subagents observed sharing one slug)
```

**Impact on card linking**: If slug is used as an association key, all subagent
sessions would be linked to the same card as the parent. This is incorrect — subagents
are independent work items. The reconciler should NOT use slug for matching.

### Entity Relationship Diagram

```
  ┌─────────────────┐           ┌─────────────────┐
  │  PROJECT DIR    │  1:N      │      SLUG       │  1:N (with inheritance)
  │  (encoded cwd)  │──────┐    │ (server-assigned)│──────┐
  └─────────────────┘      │    └─────────────────┘      │
                           │         ⚠ NOT UNIQUE                │
                           │         per conversation            │
                           ▼                              ▼
                 ┌──────────────────────────────────────────┐
                 │              SESSION                      │
                 │           (sessionId = UUID)               │
                 │                                            │
                 │  One UUID = one JSONL file = one context   │
                 │  May be a parent or a subagent child       │
                 └─────────┬──────────────────────┬──────────┘
                           │ 1:1                  │ 1:N
                           ▼                      ▼
                 ┌──────────────┐       ┌──────────────────┐
                 │ SESSION FILE │       │   HOOK EVENT     │
                 │ {uuid}.jsonl │       │  (timestamped)   │
                 └──────────────┘       └──────────────────┘

  ┌─────────────────┐
  │ TMUX TERMINAL   │  1:N
  │ (session name)  │──────→ SESSION (via hook's tmuxSession field)
  └─────────────────┘        ⚠ Only 3.9% of sessions have tmux
```

---

## Association Hierarchy for Card Linking

When determining which card a session belongs to:

```
  1. TMUX NAME (strongest — immediate, deterministic)
     │ • Contains card ID in name format
     │ • Available at SessionStart hook (tmuxSession field)
     │ • If NULL → DO NOT MATCH, fall through
     │ • Only 3.9% of sessions have this — but it's 100% reliable
     │
  2. NO MATCH → Create discovered card
     │ • Sessions with no tmux are orphans from ClaudeBoard's perspective
     │
  ✘  SLUG — NOT SAFE as association key (subagent inheritance causes collisions)
  ✘  SESSION ID — NEVER an association key (too ephemeral)
  ✘  PROJECT PATH — NEVER an association key (too broad)
```

**Critical change from previous version**: Slug has been **demoted from Level 2 to
excluded**. The subagent inheritance behavior means a single slug can span 1 parent +
N unrelated subagent sessions, making it unsuitable for card-to-session matching.

**Slug as card metadata (safe use)**: Slug can still be stored on a card as a display
property (shown in card detail view, used for session history grouping). It just cannot
be used to LINK sessions to cards during reconciliation.

**Null keys NEVER match.** A null tmux does not mean "try to match by project path."
Null means "no data for this key — create discovered card."

### Reconciler Merge on New Data

When new data arrives (SessionStart hook fires):

1. **SessionStart with tmux name containing card ID** → link session to card immediately
2. **Session has no tmux** → remains as discovered card (or not created at all if
   filtered by session age/size thresholds)

Slug-based merging of discovered cards into managed cards is **no longer recommended**.
If a user resumes a conversation from a different terminal (no tmux), it appears as a
new discovered card. This is acceptable — the user can manually merge if needed, and
AutoCleanup handles stale discovered cards.

---

## Empirical Observations

### Dataset

- **Date of analysis**: 2026-03-21
- **Total sessions**: 789 across 6 project directories
- **Primary directory**: `-Users-ciro` with 760 sessions (96%)
- **Date range**: 2026-03-15 to 2026-03-21 (7 days)
- **Hook events**: 3988 events in `~/.claude-board/hook-events.jsonl`

### Session Volume

| Date | Sessions | Notes |
|------|----------|-------|
| 03-15 | 39 | |
| 03-16 | 29 | |
| 03-17 | 14 | Weekend |
| 03-18 | 34 | |
| 03-19 | 613 | Anomaly: 584 short sessions (<10 msgs), likely batch subagents |
| 03-20 | 17 | |
| 03-21 | 33 | Partial day |

### Slug Statistics

| Metric | Value |
|--------|-------|
| Sessions with slug | 143/789 (18.1%) |
| Unique slugs | 128 |
| Slugs shared by multiple sessions | 4 (3.1%) |
| True collisions (different conversations) | 3 (2.3%) — all from subagent inheritance |
| Context continuations (same conversation) | 1 (rippling-painting-cherny: --resume next day) |

### Slug Collision Detail

| Slug | Sessions | Parents | Subagents | Distinct Topics |
|------|----------|---------|-----------|-----------------|
| immutable-finding-mist | 9 | 1 | 8 | 8 |
| cozy-moseying-pudding | 4 | 1 | 3 | 3 |
| snazzy-kindling-boot | 4 | 1 | 3 | 3 |
| rippling-painting-cherny | 2 | 2 | 0 | 1 (true continuation) |

### Hook Event Statistics

| Metric | Value |
|--------|-------|
| Total hook events | 3988 |
| SessionStart events | 805 |
| SessionStart with tmuxSession | 31 (3.9%) |
| SessionStart without tmuxSession | 774 (96.1%) |
| Unique tmux names | 16 |
| Tmux names containing card_id | 14 |
| External tmux names (claude-XXXXX) | 2 |
| Hook events containing slug | 0 |

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
All scheduled tasks run from home directory and collided with the CB card.

**Lesson**: Project path matching is fundamentally broken for home-directory sessions.
Tmux name (with embedded card ID) is the only reliable immediate association key.

---

## Validation Summary

| # | Claim | Status | Evidence |
|---|-------|--------|----------|
| 1 | One sessionId = one JSONL file | CONFIRMED | 789/789 unique |
| 2 | Slug = logical conversation | BROKEN | 3 slugs collide across unrelated conversations due to subagent inheritance |
| 3 | Slug present in ~18% of sessions | CONFIRMED | 143/789 = 18.1% |
| 4 | Slug appears after first assistant response | REVISED | True for parent sessions (129/143), false for subagents (14/143 inherit before assistant) |
| 5 | Slug null for subagents | BROKEN | 14 subagent sessions have slug (inherited from parent) |
| 6 | New sessionId on every operation | CONFIRMED | Subagent + compaction evidence present |
| 7 | SessionId is ephemeral | CONFIRMED | 12-minute average gap, high churn |
| 8 | Project path too broad | CONFIRMED | 96% of sessions share `-Users-ciro` |
| 9 | Slug not in hook events | CONFIRMED | 0/3988 hook events contain slug |
| 10 | Slug → Session is 1:N | REVISED | 1:N with inheritance — parent + children share slug |
| 11 | Tmux → Session is 1:N | CONFIRMED | Up to 7 sessions per tmux name |
| 12 | Hook input includes cwd | UNVERIFIED | Not found in 3988 hook events (may be version-dependent) |

---

## Sources

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [How Claude Code Works](https://code.claude.com/docs/en/how-claude-code-works)
- [Session ID changes when resuming — GitHub Issue #12235](https://github.com/anthropics/claude-code/issues/12235)
- [/clear starts a new session — GitHub Issue #32871](https://github.com/anthropics/claude-code/issues/32871)
- [How Claude Code Session Continuation Works — Jesse Vincent](https://blog.fsck.com/releases/2026/02/22/claude-code-session-continuation/)
- [Claude Code Session Management — Steve Kinney](https://stevekinney.com/courses/ai-development/claude-code-session-management)
- Empirical analysis of 789 session files across 6 project directories (2026-03-21)
- Empirical analysis of 3988 hook events in `~/.claude-board/hook-events.jsonl` (2026-03-21)
