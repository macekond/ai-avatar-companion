import SwiftUI
import WebKit

/// Hosts the existing three.js/VRM frontend (`ui/dist`, bundled into the app
/// under `www/` by the Xcode prebuild script — see project.yml) largely
/// unchanged. `ui/src/main.js` connects to `ws://localhost:8765` unmodified;
/// `NovaWebSocketServer` runs in-process inside this app and answers on that
/// same loopback port, so no frontend code needs to change (Phase 1 of the
/// iOS port plan).
struct ContentView: View {
    @StateObject private var server = NovaWebSocketServer(port: 8765)

    var body: some View {
        WebView()
            .ignoresSafeArea()
            .task {
                do {
                    try server.start()
                } catch {
                    // A bind failure here (e.g. port already in use) is fatal
                    // to the app's only communication channel with the UI —
                    // surfacing it loudly during Phase 1 bring-up is more
                    // useful than a silently dead WebSocket.
                    assertionFailure("NovaWebSocketServer failed to start: \(error)")
                }
            }
    }
}

private struct WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        guard let schemeHandler = NovaSchemeHandler() else {
            assertionFailure("Bundled www/ not found — did the prebuild script run?")
            return WKWebView(frame: .zero)
        }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: NovaSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: NovaSchemeHandler.appURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
