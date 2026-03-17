import SwiftUI
import WebKit

/// Reusable WKWebView-based markdown renderer with Dracula theme.
/// Used by Summary tab and potentially other tabs that need rich markdown display.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadMarkdown(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        guard markdown != coord.lastMarkdown else { return }
        loadMarkdown(into: webView, coordinator: coord)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadMarkdown(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastMarkdown = markdown

        let transformed = ReplyTabView.transformInsightBlocks(markdown)

        let escapedMd = transformed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let html = ReplyTabView.htmlPage(body: """
            <div id="content"></div>
            <script>\(ReplyTabView.markedJs)</script>
            <script>
                document.getElementById('content').innerHTML = marked.parse(`\(escapedMd)`);
            </script>
            """)

        webView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastMarkdown: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other { return .allow }
            return .cancel
        }
    }
}
