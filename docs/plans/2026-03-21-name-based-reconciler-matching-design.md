# Name-based Reconciler Matching for Manual TASK Cards

## Problem

When a user creates a name-only TASK card in ClaudeBoard and then starts a Claude session externally, the reconciler cannot link them. The TASK card has no sessionLink, tmuxLink, promptBody, or slug — all four matching strategies fail. Result: a duplicate card appears in In Progress while the original TASK stays stuck in Waiting.

## Solution

Add two new matching steps to `CardReconciler.findCardForSession`, inserted between the existing promptBody match (step 3) and slug match (step 4):

**Step 3.5 — Name-to-slug match (high confidence)**
For manual/todoist cards with no sessionLink and a `name`, normalize the name to slug form (`"sync meetings"` → `"sync-meetings"`) and compare against the session's `slug`. Match if they're equal after normalization.

**Step 3.6 — Solo project-path match (lower confidence)**
For manual/todoist cards with no sessionLink, no tmuxLink, and a `projectPath`, match if:
- The session's `projectPath` matches the card's `projectPath`
- There is exactly one such unmatched card for that project (no ambiguity)

## Normalization

A pure function `slugify(_ name: String) -> String`:
- Lowercase
- Replace whitespace runs with `-`
- Strip non-alphanumeric (except `-`)
- Collapse consecutive `-` into one
- Trim leading/trailing `-`

Example: `"Sync Meetings!"` → `"sync-meetings"`

For comparison, the session slug is also passed through `slugify` to handle any format differences.

## Changes

| File | Change |
|------|--------|
| `CardReconciler.swift` | Add `slugify()`, add steps 3.5 and 3.6 in `findCardForSession`, build `cardIdByName` index |
| `CardReconcilerTests.swift` | Tests for name-to-slug match, solo project match, ambiguous project (no match), normalization edge cases |

## What does NOT change

- Existing 4 match strategies (sessionId, projectPath+tmux, promptBody, slug)
- Slug dedup logic (section B)
- Column assignment, launch flow, effect handler

## Edge cases

- Multiple TASK cards with same name: first match wins (same as existing slug matching)
- Multiple TASK cards for same project (step 3.6): no match — ambiguity guard
- Card name doesn't match slug: falls through to step 4 then new card
- Archived cards: already handled by `manuallyArchived` check
