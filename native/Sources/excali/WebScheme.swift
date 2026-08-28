import Foundation
import WebKit

/// Serves the bundled Vite/Excalidraw build from `Contents/Resources/web` over the `excali://`
/// scheme, so absolute asset paths (`/assets/...`, `/excalidraw-assets/...`) resolve offline.
final class WebSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL?

    override init() {
        root = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root else {
            task.didFailWithError(NSError(domain: "excali", code: 500))
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        // Prevent path traversal.
        let clean = (path as NSString).standardizingPath
        let fileURL = root.appendingPathComponent(clean)
        guard fileURL.path.hasPrefix(root.path),
              let data = try? Data(contentsOf: fileURL)
        else {
            task.didFailWithError(NSError(domain: "excali", code: 404))
            return
        }
        let headers = [
            "Content-Type": Self.mime(for: fileURL.pathExtension),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
