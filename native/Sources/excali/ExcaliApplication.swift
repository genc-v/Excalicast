import AppKit

/// Custom application so we can intercept trackpad magnify (pinch) events centrally — the most
/// reliable point, since every event passes through `sendEvent`. WKWebView otherwise swallows
/// pinch gestures without forwarding them to the page.
@objc(ExcaliApplication)
final class ExcaliApplication: NSApplication {
    static var onMagnify: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .magnify, let handler = ExcaliApplication.onMagnify {
            handler(event)
            return // consume — don't let the WebView page-zoom
        }
        super.sendEvent(event)
    }
}
