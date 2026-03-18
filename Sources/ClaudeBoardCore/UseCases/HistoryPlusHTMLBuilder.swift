import Foundation

/// Pure function: transforms conversation turns into chat-bubble HTML for History+ tab.
/// Filters out tool-use, tool-result, and thinking blocks — only renders text.
public enum HistoryPlusHTMLBuilder {

    /// Build HTML message divs from conversation turns.
    /// Each turn becomes a div with class "message user-msg" or "message assistant-msg"
    /// and a `data-md` attribute containing the escaped markdown.
    /// Turns with no text blocks are skipped entirely.
    /// The caller must load marked.js and then run the render script to parse data-md.
    public static func buildMessagesHTML(from turns: [ConversationTurn]) -> String {
        var parts: [String] = []

        for turn in turns {
            let textBlocks = turn.contentBlocks.filter {
                if case .text = $0.kind { return true }
                return false
            }
            guard !textBlocks.isEmpty else { continue }

            let markdown = textBlocks.map(\.text).joined(separator: "\n\n")
            // Escape for HTML attribute (double-quote context)
            let attrEscaped = markdown
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")

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
    """
}
