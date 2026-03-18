import Foundation

/// Pure function: transforms conversation turns into chat-bubble HTML for History+ tab.
/// Filters out tool-use, tool-result, and thinking blocks — only renders text.
public enum HistoryPlusHTMLBuilder {

    /// Build HTML message divs from conversation turns.
    /// Each turn becomes a div with class "message user-msg" or "message assistant-msg".
    /// Turns with no text blocks are skipped entirely.
    /// The markdown inside each div is raw — caller renders via marked.js.
    public static func buildMessagesHTML(from turns: [ConversationTurn]) -> String {
        var parts: [String] = []

        for turn in turns {
            let textBlocks = turn.contentBlocks.filter {
                if case .text = $0.kind { return true }
                return false
            }
            guard !textBlocks.isEmpty else { continue }

            let markdown = textBlocks.map(\.text).joined(separator: "\n\n")
            let escaped = markdown
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")

            let cssClass = turn.role == "user" ? "user-msg" : "assistant-msg"
            parts.append("""
            <div class="message \(cssClass)">
                <script>document.currentScript.parentElement.innerHTML = marked.parse(`\(escaped)`);</script>
            </div>
            """)
        }

        return parts.joined(separator: "\n")
    }

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
