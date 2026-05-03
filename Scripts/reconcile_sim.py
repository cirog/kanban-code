#!/usr/bin/env python3
"""Reconciler simulation — deterministic cards + PID-based process detection.

Reference implementation for the Swift reconciler. Run this to see exactly
what the board should look like.

Card creation:
  - Session in tmux with card_ID → managed card (card_id from tmux name)
  - Session not in tmux → discovered card (card_id = session_id)

Column assignment:
  - managed/todoist + Claude alive → in_progress (if UserPromptSubmit) or waiting
  - managed/todoist + Claude dead  → waiting (sticky until manual archive)
  - discovered + Claude alive      → in_progress (if UserPromptSubmit) or waiting
  - discovered + Claude dead       → done (auto-archive)

Process detection:
  - Read latest PID per session from hook events
  - kill -0 $PID → alive or dead

Usage: python3 scripts/reconcile_sim.py
"""
import json
import os
import signal
import subprocess
from collections import defaultdict

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
HOOK_EVENTS = os.path.expanduser("~/.claude-board/hook-events.jsonl")


def extract_card_id(tmux_name):
    """Extract card ID from tmux name. Returns None if not a managed session."""
    idx = tmux_name.find("card_")
    if idx < 0:
        return None
    return tmux_name[idx:]


def scan_session_files():
    """Find all .jsonl session files and return their session IDs."""
    sessions = []
    for dirpath, _, filenames in os.walk(PROJECTS_DIR):
        for f in filenames:
            if f.endswith(".jsonl"):
                session_id = f.replace(".jsonl", "")
                sessions.append(session_id)
    return sessions


def load_hook_events():
    """Load hook events. Returns:
    - tmux_to_sessions: tmux_name → [session_ids] (from SessionStart events)
    - latest_pid: session_id → pid (latest PID seen for each session)
    - latest_event: session_id → event_name (latest hook event per session)
    """
    tmux_to_sessions = defaultdict(list)
    latest_pid = {}      # session_id → int (PID)
    latest_event = {}    # session_id → str (event name)

    if not os.path.exists(HOOK_EVENTS):
        return tmux_to_sessions, latest_pid, latest_event

    with open(HOOK_EVENTS) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            sid = obj.get("sessionId", "")
            if not sid:
                continue

            event = obj.get("event", "")
            tmux = obj.get("tmuxSession", "")
            pid = obj.get("pid")

            # Track tmux → session mapping
            if event == "SessionStart" and tmux:
                tmux_to_sessions[tmux].append(sid)

            # Track latest PID per session
            if pid:
                latest_pid[sid] = int(pid)

            # Track latest event per session
            if event:
                latest_event[sid] = event

    return tmux_to_sessions, latest_pid, latest_event


def is_pid_alive(pid):
    """Check if a process is alive using kill -0."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except Exception:
        return False


def reconcile():
    # 1. Scan session files
    all_sessions = scan_session_files()
    print(f"Session files on disk: {len(all_sessions)}")

    # 2. Load hook events
    tmux_to_sessions, latest_pid, latest_event = load_hook_events()

    # 3. Build reverse map: session_id → tmux_name
    session_to_tmux = {}
    for tmux_name, sids in tmux_to_sessions.items():
        for sid in sids:
            session_to_tmux[sid] = tmux_name

    # 4. Build cards (deterministic IDs)
    cards = {}  # card_id → { sessions, source, tmux }

    for session_id in all_sessions:
        tmux_name = session_to_tmux.get(session_id)

        if tmux_name:
            card_id = extract_card_id(tmux_name)
            if card_id:
                cards.setdefault(card_id, {"sessions": [], "source": "managed", "tmux": tmux_name})
                cards[card_id]["sessions"].append(session_id)
                continue

        # Discovered: card_id = session_id (deterministic)
        card_id = session_id
        cards.setdefault(card_id, {"sessions": [], "source": "discovered"})
        cards[card_id]["sessions"].append(session_id)

    # 5. Check PIDs → is Claude running?
    pid_alive_cache = {}
    for sid, pid in latest_pid.items():
        if pid not in pid_alive_cache:
            pid_alive_cache[pid] = is_pid_alive(pid)

    # 6. Assign columns
    columns = {"in_progress": [], "waiting": [], "done": []}

    for card_id, card in cards.items():
        is_managed = card["source"] in ("managed", "todoist")

        # Is Claude running for any session in this card?
        claude_running = False
        active_session = None
        for sid in card["sessions"]:
            pid = latest_pid.get(sid)
            if pid and pid_alive_cache.get(pid, False):
                claude_running = True
                active_session = sid
                break

        if claude_running:
            # Claude is running — check last hook event
            event = latest_event.get(active_session, "")
            if event == "UserPromptSubmit":
                col = "in_progress"
            else:
                col = "waiting"
        else:
            # Claude is NOT running
            if is_managed:
                col = "waiting"   # sticky
            else:
                col = "done"      # auto-archive

        card["column"] = col
        card["claude_running"] = claude_running
        columns[col].append((card_id, card))

    # 7. Report
    print(f"Sessions with PID data: {len(latest_pid)}")
    print(f"Unique PIDs checked: {len(pid_alive_cache)}")
    print(f"PIDs alive: {sum(1 for v in pid_alive_cache.values() if v)}")

    print(f"\nTotal cards: {len(cards)}")
    print(f"  In Progress: {len(columns['in_progress'])}")
    print(f"  Waiting:     {len(columns['waiting'])}")
    print(f"  Done:        {len(columns['done'])}")

    if columns["in_progress"]:
        print(f"\n--- IN PROGRESS ---")
        for card_id, card in columns["in_progress"]:
            color = "managed" if card["source"] in ("managed", "todoist") else "discovered"
            print(f"  [{color}] {card_id}")

    if columns["waiting"]:
        print(f"\n--- WAITING ---")
        for card_id, card in columns["waiting"]:
            color = "managed" if card["source"] in ("managed", "todoist") else "discovered"
            reason = "claude running" if card["claude_running"] else "sticky (no process)"
            print(f"  [{color}] {card_id} — {reason}")

    # Show discovered cards with live Claude (should be rare/interesting)
    live_discovered = [(cid, c) for cid, c in cards.items()
                       if c["source"] == "discovered" and c["claude_running"]]
    if live_discovered:
        print(f"\n--- DISCOVERED WITH LIVE CLAUDE ({len(live_discovered)}) ---")
        for card_id, card in live_discovered:
            print(f"  {card_id}")

    print(f"\n--- DONE: {len(columns['done'])} cards (not shown on board) ---")


if __name__ == "__main__":
    reconcile()
