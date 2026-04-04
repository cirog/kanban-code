import Testing
import WebKit
@testable import ClaudeBoard

@Suite("WebViewScrollWrapper")
@MainActor
struct WebViewScrollWrapperTests {
    @Test("wraps WKWebView as subview with filling constraints")
    func wrapsWebViewAsSubview() {
        let webView = WKWebView(frame: .zero)
        let wrapper = WebViewScrollWrapper(webView: webView)

        // WebView is a subview
        #expect(wrapper.subviews.contains(webView))

        // WebView uses Auto Layout (not autoresizing mask)
        #expect(webView.translatesAutoresizingMaskIntoConstraints == false)

        // Has 4 constraints pinning edges
        #expect(wrapper.constraints.count == 4)
    }

    @Test("forwards scrollWheel events to webView")
    func forwardsScrollWheel() {
        let spy = ScrollWheelSpy(frame: .zero)
        let wrapper = WebViewScrollWrapper(webView: spy)

        // Synthesize a scroll event
        let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )!
        wrapper.scrollWheel(with: event)

        #expect(spy.scrollWheelCallCount == 1)
    }
}

/// Spy to verify scrollWheel forwarding.
private final class ScrollWheelSpy: WKWebView {
    var scrollWheelCallCount = 0

    override func scrollWheel(with event: NSEvent) {
        scrollWheelCallCount += 1
    }
}
