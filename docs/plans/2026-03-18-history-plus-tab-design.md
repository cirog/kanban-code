# History+ Tab Design

## Goal

Add a new "History+" tab to CardDetailView that renders the full conversation as a human-readable chat view using WKWebView + Dracula theme. User messages appear as right-aligned pink bubbles; assistant text responses appear left-aligned in standard Dracula styling. Tool use, tool results, and thinking blocks are filtered out.

## Architecture

A new `historyPlus` case in `DetailTab` renders a single WKWebView that reuses the existing `ReplyTabView` CSS/JS infrastructure (Dracula CSS, marked.js, `htmlPage()` template). The view displays the full conversation in a chat-style layout with live updates.

### Data Flow

1. `CardDetailView` passes the session's `jsonlPath` to a new `HistoryPlusView` (NSViewRepresentable wrapping WKWebView)
2. `HistoryPlusView` uses `TranscriptReader` to load conversation turns (same API as History tab)
3. **Filter**: keep only turns where `contentBlocks` contain `.text` kind — skip `.toolUse`, `.toolResult`, `.thinking`
4. For each kept turn, concatenate all `.text` content blocks into one markdown string
5. Build a single HTML document with all messages rendered via marked.js
6. User messages get `class="user-msg"` (right-aligned, pink bubble); assistant messages get `class="assistant-msg"` (left-aligned, standard Dracula)

### Visual Design

- **User messages**: right-aligned, `#ff79c6` (Dracula pink) at ~12% opacity background, bold text, rounded corners, max-width ~80%
- **Assistant messages**: left-aligned, standard Dracula text styling (existing CSS), max-width ~90%
- Both message types get vertical spacing between them
- Auto-scroll to bottom on initial load and on new messages
- Markdown rendering via marked.js (tables, code blocks, lists all supported)

### CSS Additions

On top of the existing Dracula CSS from `ReplyTabView.css`:

```css
.message { margin: 8px 0; padding: 12px 16px; border-radius: 12px; }
.user-msg {
    margin-left: 20%; text-align: left; font-weight: bold;
    background: rgba(255, 121, 198, 0.12); /* Dracula pink */
    border: 1px solid rgba(255, 121, 198, 0.25);
}
.assistant-msg {
    margin-right: 10%;
    /* inherits standard Dracula text styling */
}
```

### Live Reload Strategy

Same mechanism as the existing History tab:
- **DispatchSource** file watcher on the JSONL file
- **3-second polling** fallback
- Track `lastLineNumber` — on reload, only parse lines after the last known line
- Full HTML re-render on each update (WKWebView handles this efficiently; incremental DOM updates add complexity without meaningful benefit for this use case)

### Tab Placement

- New `historyPlus` case added to `DetailTab` enum
- Displayed after History in the tab bar
- No change to `initialTab()` logic — History+ is opt-in by clicking the tab
- Coexists with existing History tab (History+ is an eventual replacement, not immediate)

### Skill Usage Display

Skill invocations appear in the transcript in two forms:
1. **Slash commands** — user turns containing `<command-name>/skill:name</command-name>` tags, already parsed by `TranscriptReader.parseLocalCommand()` into clean text like `superpowers:brainstorming args...`
2. **Programmatic invocations** — assistant `.toolUse(name: "Skill")` blocks, currently filtered out by History tab

**Display**: Skill invocations rendered as left-aligned bubbles with **Dracula cyan** (`#8be9fd` at ~12% opacity) background and a skill icon prefix. Visually distinct from both user (pink) and assistant (no background) messages. Shows the skill name prominently with args as secondary text.

Detection: `HistoryPlusHTMLBuilder` checks each turn's text blocks for slash command patterns (starts with a skill namespace like `superpowers:`, `obsidian:`, `incontrol:`, etc.) and `.toolUse` blocks with `name == "Skill"`. Matched turns get `class="skill-msg"` instead of user/assistant classes.

```css
.skill-msg {
    margin-right: 10%;
    background: rgba(139, 233, 253, 0.12); /* Dracula cyan */
    border: 1px solid rgba(139, 233, 253, 0.25);
    font-size: 0.9em;
}
```

## Decisions

- **Tool blocks hidden**: Only text content shown. Tool calls/results/thinking filtered out for readability. The existing History tab remains available for full detail.
- **Dracula pink for user messages**: `#ff79c6` — native to the Dracula palette, high contrast against the dark background.
- **Reuse existing infrastructure**: `ReplyTabView.htmlPage()`, `.css`, `.markedJs`, `TranscriptReader` — no new dependencies.
- **WKWebView over SwiftUI**: Consistent with Reply tab and Summary tab. Rich markdown rendering, scrolling, and styling handled by the web engine.

## Files

- **New**: `Sources/ClaudeBoard/HistoryPlusView.swift` — NSViewRepresentable with WKWebView, file watching, HTML generation
- **Modify**: `Sources/ClaudeBoard/CardDetailView.swift` — add `historyPlus` case to `DetailTab`, add tab button, add view in tab content
- **Modify**: `Sources/ClaudeBoard/ReplyTabView.swift` — possibly extract shared CSS additions (or keep in HistoryPlusView if minimal)
