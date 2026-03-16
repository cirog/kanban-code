# Reply Tab Design

**Date**: 2026-03-16
**Status**: Approved

## Problem

Multi-step skills (daily-prep, sync-meetings, etc.) produce output where human-readable content (tables, summaries, decisions) is interleaved with technical noise (tool calls, bash output, file reads). Neither the Terminal tab (raw tmux) nor the History tab (all content blocks) provides a clean reading experience.

## Solution

A new **Reply** tab that shows only the `.text` content blocks from the last completed assistant turn, rendered as properly styled markdown in a WKWebView.

## Tab Placement

```
Terminal | Reply | History | Prompt | Description | Summary
```

Visible when `card.link.sessionLink != nil` (same condition as History).

## Rendering Pipeline

1. **On tab focus** — read the last assistant turn from `TranscriptReader`
2. **Filter** — keep only `.text` kind `ContentBlock`s
3. **Concatenate** — join text blocks with `\n\n` separator
4. **Render** — load into `WKWebView` with embedded `marked.js` + Dracula CSS
5. **Cache** — store rendered turn index; skip re-parse unless new turn arrived

## WebView Approach

- No network access — `WKWebViewConfiguration` with no navigation allowed
- Embedded assets — `marked.min.js` + CSS as bundled resources or string constants
- Dracula theme CSS:
  - Background: `#282a36`
  - Foreground: `#f8f8f2`
  - Table headers: purple accent `#bd93f9`
  - Code blocks: `#44475a` background
  - Table rows: alternating subtle striping
- Font: system default at comfortable reading size (proportional for document feel)

## Data Flow

```
TranscriptReader (existing)
  → last assistant ConversationTurn
  → filter contentBlocks where kind == .text
  → concatenate .text strings
  → inject into HTML template
  → WKWebView.loadHTMLString()
```

## Edge Cases

| Condition | Display |
|-----------|---------|
| No session | "No session" placeholder |
| No assistant turns yet | "Waiting for reply..." |
| Turn has zero `.text` blocks | "No text output in last reply" |
| Very long output | WebView native scrolling |

## Scope Exclusions

- No live streaming / partial updates
- No tool call indicators
- No thinking blocks
- No interaction (no buttons, checkpoints, or search)
