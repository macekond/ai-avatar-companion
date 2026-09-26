import WebKit

/// Serves the bundled `ui/dist` build (`www/` in the app bundle) over a
/// custom URL scheme instead of `file://`.
///
/// `file://` origins are CORS-opaque in WKWebView, and `<script
/// type="module" crossorigin>` (what Vite emits) always performs a CORS
/// check on the module fetch — one that can never succeed against an opaque
/// origin. The module script silently fails to load, so `ui/src/main.js`
/// never runs at all (confirmed empirically: no JS-driven UI ever appears,
/// only the page's static HTML). A custom scheme gives the page a stable,
/// consistent origin that the module fetch's same-origin check matches, so
/// this sidesteps the restriction entirely rather than working around it.
final class NovaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "nova-app"
    static let appURL = URL(string: "\(scheme)://local/index.html")!

    private let wwwRoot: URL

    init?(wwwRoot: URL? = Bundle.main.url(forResource: "www", withExtension: nil)) {
        guard let wwwRoot else { return nil }
        self.wwwRoot = wwwRoot
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // "nova-app://local/assets/foo.js" -> "assets/foo.js"; empty path
        // (bare "nova-app://local") -> "index.html".
        let relativePath = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let fileURL = wwwRoot.appendingPathComponent(relativePath).standardizedFileURL

        // Defense in depth: only the bundled JS ever requests through this
        // scheme today (same-origin, not attacker-controlled), but a
        // relativePath containing "../" would otherwise resolve outside
        // wwwRoot with no check at all. Reject anything that escapes it
        // rather than trusting the request path never will.
        guard fileURL.path.hasPrefix(wwwRoot.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: fileURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: url, mimeType: Self.mimeType(for: fileURL.pathExtension),
            expectedContentLength: data.count, textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "vrm", "glb": return "model/gltf-binary"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
