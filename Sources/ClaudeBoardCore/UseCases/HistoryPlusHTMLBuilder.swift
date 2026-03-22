import Foundation

/// Pure function: transforms conversation turns into chat-bubble HTML for History+ tab.
/// Filters out tool-use, tool-result, and thinking blocks — only renders text.
public enum HistoryPlusHTMLBuilder {

    /// Build HTML message divs from conversation turns.
    /// Each turn becomes a div with class "message user-msg" or "message assistant-msg"
    /// and a `data-md` attribute containing the escaped markdown.
    /// Turns with no text blocks are skipped entirely.
    /// The caller must load marked.js and then run the render script to parse data-md.
    public static func buildMessagesHTML(
        from turns: [ConversationTurn],
        transformMarkdown: ((String) -> String)? = nil
    ) -> String {
        var parts: [String] = []

        for turn in turns {
            // Check for skill invocations first
            let skillName = detectSkill(in: turn)
            if let skill = skillName {
                let escaped = escapeForAttribute(skill)
                parts.append("""
                <div class="message skill-msg" data-md="\(escaped)"></div>
                """)
                continue
            }

            let textBlocks = turn.contentBlocks.filter {
                if case .text = $0.kind { return true }
                return false
            }
            guard !textBlocks.isEmpty else { continue }

            var markdown = textBlocks.map(\.text).joined(separator: "\n\n")
            if let transform = transformMarkdown {
                markdown = transform(markdown)
            }
            let attrEscaped = escapeForAttribute(markdown)

            let cssClass = turn.role == "user" ? "user-msg" : "assistant-msg"
            parts.append("""
            <div class="message \(cssClass)" data-md="\(attrEscaped)"></div>
            """)
        }

        return parts.joined(separator: "\n")
    }

    /// JavaScript to render all data-md divs via marked.parse(). Run after marked.js loads.
    public static let renderScript: String = """
        document.querySelectorAll('[data-md]').forEach(el => {
            el.innerHTML = marked.parse(el.getAttribute('data-md'));
        });
        window.scrollTo(0, document.body.scrollHeight);
    """

    /// Additional CSS for chat-bubble layout (appended to base Dracula CSS).
    public static let chatCSS: String = """
        .message {
            margin: 12px 0;
            padding: 12px 16px;
            border-radius: 12px;
            line-height: 1.6;
            overflow-wrap: break-word;
        }
        .user-msg {
            margin-left: 20%;
            text-align: left;
            font-weight: bold;
            background: rgba(255, 121, 198, 0.12);
            border: 1px solid rgba(255, 121, 198, 0.25);
        }
        .user-msg p { margin: 0.3em 0; }
        .assistant-msg {
            margin-right: 10%;
        }
        .assistant-msg:last-child { margin-bottom: 40px; }
        .skill-msg {
            margin-right: 10%;
            background: rgba(139, 233, 253, 0.12);
            border: 1px solid rgba(139, 233, 253, 0.25);
            font-size: 0.9em;
        }
        .session-divider {
            display: flex;
            align-items: center;
            margin: 24px 0;
            gap: 12px;
        }
        .divider-line {
            flex: 1;
            height: 1px;
            background: rgba(98, 114, 164, 0.4);
        }
        .divider-text {
            color: rgba(98, 114, 164, 0.8);
            font-size: 0.8em;
            white-space: nowrap;
            font-style: italic;
        }
    """

    // MARK: - Session Dividers

    /// Build HTML for a session transition divider.
    public static func buildSessionDividerHTML(reason: String, gap: String?, timestamp: String) -> String {
        var parts: [String] = [reason]
        if let gap { parts.append(gap) }
        parts.append(timestamp)
        let text = parts.joined(separator: " · ")

        return """
        <div class="session-divider">
            <span class="divider-line"></span>
            <span class="divider-text">\(escapeForAttribute(text))</span>
            <span class="divider-line"></span>
        </div>
        """
    }

    /// Build HTML with session dividers inserted between groups.
    public static func buildSegmentedMessagesHTML(
        segments: [(dividerHTML: String?, turns: [ConversationTurn])],
        transformMarkdown: ((String) -> String)? = nil
    ) -> String {
        var parts: [String] = []
        for segment in segments {
            if let divider = segment.dividerHTML {
                parts.append(divider)
            }
            parts.append(buildMessagesHTML(from: segment.turns, transformMarkdown: transformMarkdown))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Prompts HTML

    /// Build HTML for the prompts tab: user messages grouped by session with collapsible sections.
    public static func buildPromptsHTML(
        groups: [(sessionLabel: String, dividerHTML: String?, prompts: [ConversationTurn])]
    ) -> String {
        var parts: [String] = []

        for (i, group) in groups.enumerated() {
            if let divider = group.dividerHTML, i > 0 {
                parts.append(divider)
            }

            if groups.count > 1 {
                parts.append("""
                <details \(i == groups.count - 1 ? "open" : "")>
                    <summary class="session-header">\(escapeForAttribute(group.sessionLabel))</summary>
                """)
            }

            for prompt in group.prompts {
                let textBlocks = prompt.contentBlocks.filter { if case .text = $0.kind { true } else { false } }
                guard !textBlocks.isEmpty else { continue }
                let markdown = textBlocks.map(\.text).joined(separator: "\n\n")
                let escaped = escapeForAttribute(markdown)
                let ts = prompt.timestamp ?? ""
                let tsEscaped = escapeForAttribute(ts)

                parts.append("""
                <div class="prompt-entry">
                    <span class="prompt-ts">\(tsEscaped)</span>
                    <div class="prompt-body" data-md="\(escaped)"></div>
                </div>
                """)
            }

            if groups.count > 1 {
                parts.append("</details>")
            }
        }

        return parts.joined(separator: "\n")
    }

    /// CSS for prompts tab.
    public static let promptsCSS: String = """
        .session-header {
            color: rgba(98, 114, 164, 0.8);
            font-size: 0.85em;
            cursor: pointer;
            padding: 8px 0;
            font-style: italic;
        }
        .session-header:hover { color: rgba(139, 233, 253, 0.8); }
        details { margin: 8px 0; }
        .prompt-entry {
            padding: 12px 16px;
            border-bottom: 1px solid rgba(68, 71, 90, 0.5);
        }
        .prompt-ts {
            display: block;
            font-size: 0.75em;
            color: rgba(98, 114, 164, 0.6);
            font-family: monospace;
            margin-bottom: 6px;
        }
        .prompt-body {
            line-height: 1.6;
        }
        .prompt-body p { margin: 0.3em 0; }
        .prompt-body code {
            background: rgba(68, 71, 90, 0.5);
            padding: 2px 4px;
            border-radius: 3px;
            font-size: 0.9em;
        }
        .prompt-body pre {
            background: rgba(40, 42, 54, 0.8);
            padding: 12px;
            border-radius: 6px;
            overflow-x: auto;
        }
    """

    // MARK: - Helpers

    /// Detect if a turn is a skill invocation. Returns formatted skill display text or nil.
    private static func detectSkill(in turn: ConversationTurn) -> String? {
        // Check for Skill tool_use blocks (assistant programmatic invocation)
        for block in turn.contentBlocks {
            if case .toolUse(let name, let input) = block.kind, name == "Skill" {
                let skill = input["skill"] ?? "unknown"
                return "**Skill** `\(skill)`"
            }
        }
        // Check for slash command invocations (user text starting with namespace:name pattern)
        // Require namespace ≥2 chars, name ≥2 chars, and reject URL-scheme prefixes
        for block in turn.contentBlocks {
            if case .text = block.kind {
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = text.range(of: #"^[\w-]{2,}:[\w-]{2,}"#, options: .regularExpression) {
                    let skillName = String(text[match])
                    let namespace = skillName.prefix(while: { $0 != ":" })
                    guard !["http", "https", "ftp", "ftps", "mailto", "tel", "ssh", "data", "re", "fw", "fwd"].contains(String(namespace)) else { continue }
                    let args = String(text[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if args.isEmpty {
                        return "**Skill** `\(skillName)`"
                    }
                    return "**Skill** `\(skillName)` — \(String(args.prefix(80)))"
                }
            }
        }
        return nil
    }

    /// Escape markdown for HTML attribute (double-quote context).
    private static func escapeForAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
