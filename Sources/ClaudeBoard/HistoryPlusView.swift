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

        if coord.didInitialLoad {
            // Incremental update: replace content via JS — no page reload, no scroll jump.
            incrementalUpdate(webView: webView, coordinator: coord)
        } else {
            loadHTML(into: webView, coordinator: coord)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Full HTML load — used only for the initial render.
    private func loadHTML(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastLineNumber = turns.last?.lineNumber ?? -1
        coordinator.lastTurnCount = turns.count

        let messagesHTML = buildCurrentHTML()

        let html = ReplyTabView.htmlPage(body: """
            <style>\(HistoryPlusHTMLBuilder.chatCSS)</style>
            <div id="content">
                \(messagesHTML)
            </div>
            <script>\(ReplyTabView.markedJs)</script>
            <script>\(HistoryPlusHTMLBuilder.renderScript)</script>
            """)

        webView.loadHTMLString(html, baseURL: nil)
        coordinator.didInitialLoad = true
    }

    /// Incremental update — replaces #content innerHTML via JavaScript.
    /// Avoids WKWebView page reload which causes visible scroll-to-top flash.
    private func incrementalUpdate(webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastLineNumber = turns.last?.lineNumber ?? -1
        coordinator.lastTurnCount = turns.count

        let messagesHTML = buildCurrentHTML()
        // Escape for JS string literal (backslash, backtick, dollar sign)
        let jsEscaped = messagesHTML
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let js = """
        (function() {
            var c = document.getElementById('content');
            if (!c) return;
            c.innerHTML = `\(jsEscaped)`;
            document.querySelectorAll('[data-md]').forEach(function(el) {
                el.innerHTML = marked.parse(el.getAttribute('data-md'));
            });
            window.scrollTo(0, document.body.scrollHeight);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Build the messages HTML for current state.
    private func buildCurrentHTML() -> String {
        if let segments {
            return HistoryPlusHTMLBuilder.buildSegmentedMessagesHTML(
                segments: segments,
                transformMarkdown: ReplyTabView.transformInsightBlocks
            )
        } else {
            return HistoryPlusHTMLBuilder.buildMessagesHTML(
                from: turns,
                transformMarkdown: ReplyTabView.transformInsightBlocks
            )
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastLineNumber: Int = -1
        var lastTurnCount: Int = 0
        var didInitialLoad = false

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other { return .allow }
            return .cancel
        }
    }
}
