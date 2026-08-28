import AppKit
import CoreGraphics
import WebKit

/// A borderless, non-activating panel that can still become key (for Excalidraw's keyboard
/// shortcuts) and join other apps' fullscreen Spaces without switching Spaces.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the overlay panel + WKWebView and services the JS bridge commands.
final class OverlayController: NSObject, WKScriptMessageHandlerWithReply {
    let panel: OverlayPanel
    let webView: WKWebView
    private var pendingOpenPath: String?

    override init() {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).frame

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebSchemeHandler(), forURLScheme: "excalicast")
        let ucc = WKUserContentController()
        config.userContentController = ucc

        webView = WKWebView(frame: CGRect(origin: .zero, size: frame.size), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground") // transparent webview
        webView.allowsMagnification = false // we translate pinch into Excalidraw ctrl+wheel ourselves
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }

        panel = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = webView
        panel.initialFirstResponder = webView

        super.init()

        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "invoke")
        applyAppearance()
        webView.load(URLRequest(url: URL(string: "excalicast://app/index.html")!))
    }

    /// Translate a trackpad magnify event into a ctrl+wheel zoom at the cursor for Excalidraw.
    func forwardPinch(_ event: NSEvent) {
        guard panel.isVisible else { return }
        let viewPoint = webView.convert(event.locationInWindow, from: nil)
        let x = viewPoint.x
        let y = webView.bounds.height - viewPoint.y // NSView is bottom-left; CSS is top-left
        let wheelDelta = -event.magnification * 400.0
        let js = "window.__excaliPinch && window.__excaliPinch(\(x), \(y), \(wheelDelta))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// The overlay is always light: Excalidraw's dark theme would invert the screenshot on WebKit
    /// (no canvas-filter support to counter-invert images). The appearance setting themes the
    /// native UI (Settings window) via `NSApp.appearance` instead.
    func applyAppearance() {
        let light = NSAppearance(named: .aqua)
        webView.appearance = light
        panel.appearance = light
    }

    /// Whether the system is in dark mode (the overlay's canvas colors follow the system).
    func isDarkEffective() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    var isShown: Bool { panel.isVisible }

    /// Open a saved `.excalidraw` file for continued editing.
    func openFile(path: String) {
        pendingOpenPath = path
        emit("open-file")
    }

    // MARK: - Native -> JS

    func emit(_ event: String) {
        let js = "window.__excaliEmit && window.__excaliEmit('\(event)')"
        DispatchQueue.main.async { self.webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    // MARK: - JS -> Native (WKScriptMessageHandlerWithReply)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "malformed bridge message")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        handle(cmd: cmd, args: args, reply: replyHandler)
    }

    private func handle(cmd: String, args: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        switch cmd {
        case "check_screen_permission":
            reply(CGPreflightScreenCaptureAccess(), nil)

        case "request_screen_permission":
            reply(CGRequestScreenCaptureAccess(), nil)

        case "open_screen_recording_settings":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            reply(nil, nil)

        case "get_settings":
            reply([
                "dark": isDarkEffective(),
                "gridEnabled": SettingsStore.gridEnabled,
            ], nil)

        case "get_pending_file":
            if let p = pendingOpenPath,
               let content = try? String(contentsOfFile: p, encoding: .utf8) {
                reply(["path": p, "content": content], nil)
            } else {
                reply(nil, nil)
            }

        case "save_to_file":
            let path = args["path"] as? String ?? ""
            let b64 = args["pngB64"] as? String ?? ""
            let excalidraw = args["excalidraw"] as? String ?? ""
            reply(saveToFile(path: path, pngB64: b64, excalidraw: excalidraw), nil)

        case "hide_overlay":
            panel.orderOut(nil)
            reply(nil, nil)

        case "show_overlay":
            let w = args["widthPx"] as? Int
            let h = args["heightPx"] as? Int
            showOverlay(widthPx: w, heightPx: h)
            reply(nil, nil)

        case "copy_png_to_clipboard":
            if let b64 = args["pngB64"] as? String, let data = Self.decodePNG(b64) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(data, forType: .png)
                reply(nil, nil)
            } else {
                reply(nil, "no image data")
            }

        case "save_annotation":
            let b64 = args["pngB64"] as? String ?? ""
            let excalidraw = args["excalidraw"] as? String ?? ""
            reply(saveAnnotation(pngB64: b64, excalidraw: excalidraw), nil)

        case "capture_screen":
            Task {
                do {
                    let result = try await Capture.captureUnderCursor()
                    await MainActor.run { reply(result.dict, nil) }
                } catch {
                    await MainActor.run { reply(nil, error.localizedDescription) }
                }
            }

        default:
            reply(nil, "unknown command: \(cmd)")
        }
    }

    // MARK: - Window placement

    func showOverlay(widthPx: Int?, heightPx: Int?) {
        let screen = pickScreen(widthPx: widthPx, heightPx: heightPx)
        panel.setFrame(screen.frame, display: true)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        // Activate so macOS delivers trackpad magnify (pinch) gestures — those only reach the
        // active app. The panel is non-activating and joins the current Space, so this shouldn't
        // switch Spaces away from a fullscreen app.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pickScreen(widthPx: Int?, heightPx: Int?) -> NSScreen {
        if let w = widthPx, let h = heightPx {
            let matches = NSScreen.screens.filter {
                Int(($0.frame.width * $0.backingScaleFactor).rounded()) == w
                    && Int(($0.frame.height * $0.backingScaleFactor).rounded()) == h
            }
            if matches.count == 1 { return matches[0] }
        }
        return Capture.screenUnderCursor()
    }

    // MARK: - Helpers

    private static func decodePNG(_ s: String) -> Data? {
        let raw = s.hasPrefix("data:image/png;base64,")
            ? String(s.dropFirst("data:image/png;base64,".count))
            : s
        return Data(base64Encoded: raw)
    }

    /// Overwrite an existing `.excalidraw` (and its sibling `.png`) in place.
    private func saveToFile(path: String, pngB64: String, excalidraw: String) -> String {
        let url = URL(fileURLWithPath: path)
        if !excalidraw.isEmpty {
            try? excalidraw.write(to: url, atomically: true, encoding: .utf8)
        }
        let png = url.deletingPathExtension().appendingPathExtension("png")
        if let data = Self.decodePNG(pngB64) {
            try? data.write(to: png)
        }
        pruneSavedFiles()
        return path
    }

    /// Create a new annotation file pair and return the `.excalidraw` path.
    private func saveAnnotation(pngB64: String, excalidraw: String) -> String {
        let dir = SettingsStore.resolvedSaveDir()
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let base = "\(dir)/Annotation-\(ts)"
        if let data = Self.decodePNG(pngB64) {
            try? data.write(to: URL(fileURLWithPath: base + ".png"))
        }
        if !excalidraw.isEmpty {
            try? excalidraw.write(toFile: base + ".excalidraw", atomically: true, encoding: .utf8)
        }
        pruneSavedFiles()
        return base + ".excalidraw"
    }
}
