# Todoist Integration — Design Document

**Date:** 2026-03-15
**Status:** Approved

## Problem

Todoist tasks labeled `@claude` need manual recreation as board cards. No link between task completion on the board and Todoist status.

## Solution

One-way sync: Todoist `@claude` tasks auto-create Backlog cards. Archiving a card completes the Todoist task. Task description visible as a tab in the detail pane.

## Data Model Changes

### Link.swift
- Add `todoistId: String?` — Todoist task ID for completion sync
- Add `todoistDescription: String?` — task description shown in detail pane
- Both fields use `decodeIfPresent` for backward compatibility

### LinkSource enum
- Add `.todoist` case

### CardLabel enum
- Add `.todoist` case (shows Todoist icon)

## Sync Service

New `TodoistSyncService.swift` (actor, same pattern as `UsageService`):

### Inbound Sync (every 5 min + startup)
```
~/.local/bin/todoist task list --label claude --format json
```
- For each task: if no card with matching `todoistId` exists → create card in Backlog
- For each existing Todoist card: check if task was completed externally → move to Done
- Card fields: `name=content`, `promptBody=content`, `todoistDescription=description`, `source=.todoist`, `column=.backlog`

### Outbound Sync (on archive)
When a card with `todoistId` moves to Done:
```
~/.local/bin/todoist task complete --ids <todoistId>
```
Fire-and-forget with logging.

## Launch Flow

Todoist Backlog card → play button → prompt editor pre-filled with task title → user edits → launch.

## Detail Pane

New "Description" tab alongside Terminal and History tabs in `CardDetailView`:
- Shows `todoistDescription` as scrollable text
- Only appears on cards that have a description
- Read-only

## Sync Timing

- Startup: immediate fetch
- Polling: every 5 minutes
- Completion: triggered synchronously on archive action

## CLI Dependency

Uses `~/.local/bin/todoist` CLI (already installed). No API key needed — CLI handles auth.
