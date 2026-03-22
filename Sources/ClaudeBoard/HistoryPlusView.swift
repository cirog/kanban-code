import SwiftUI
import WebKit
import ClaudeBoardCore

/// WKWebView-based chat renderer for History+ tab.
/// Shows full conversation with user messages as pink bubbles (right) and
/// assistant text as Dracula-styled markdown (left), and tool activity as compact green indicators.
struct HistoryPlusView: NSViewRepresentable {
    let turns: [ConversationTurn]
    /// Optional session segments with divider HTML. When provided, renders segmented view with dividers.
    var segments: [(dividerHTML: String?, turns: [ConversationTurn])]?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadHTML(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        let currentLine = turns.last?.lineNumber ?? -1
        guard currentLine != coord.lastLineNumber else { return }
        loadHTML(into: webView, coordinator: coord)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadHTML(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastLineNumber = turns.last?.lineNumber ?? -1

        let messagesHTML: String
        if let segments {
            messagesHTML = HistoryPlusHTMLBuilder.buildSegmentedMessagesHTML(
                segments: segments,
                transformMarkdown: ReplyTabView.transformInsightBlocks
            )
        } else {
            messagesHTML = HistoryPlusHTMLBuilder.buildMessagesHTML(
                from: turns,
                transformMarkdown: ReplyTabView.transformInsightBlocks
            )
        }

        let html = ReplyTabView.htmlPage(body: """
            <style>\(HistoryPlusHTMLBuilder.chatCSS)</style>
            <div id="content">
                \(messagesHTML)
            </div>
            <script>\(ReplyTabView.markedJs)</script>
            <script>\(HistoryPlusHTMLBuilder.renderScript)</script>
            """)

        webView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastLineNumber: Int = -1

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other { return .allow }
            return .cancel
        }
    }
}
