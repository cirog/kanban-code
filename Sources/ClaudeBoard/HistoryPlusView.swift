import SwiftUI
import WebKit
import ClaudeBoardCore

/// WKWebView-based chat renderer for History+ tab.
/// Shows full conversation with user messages as pink bubbles (right) and
/// assistant text as Dracula-styled markdown (left). Tool/thinking blocks filtered.
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
        let currentCount = turns.count
        guard currentCount != coord.lastTurnCount else { return }
        loadHTML(into: webView, coordinator: coord)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadHTML(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastTurnCount = turns.count

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
        var lastTurnCount: Int = 0

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other { return .allow }
            return .cancel
        }
    }
}
