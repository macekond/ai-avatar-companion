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
    /// Locks pinch/double-tap zoom on the hosted page (C2) — rapid taps on
    /// the talk button were triggering WKWebView's built-in double-tap-zoom,
    /// and focusing a text input auto-zooms too, leaving a kid stuck zoomed
    /// in with no way back out. `viewForZooming` returning nil is the
    /// documented way to make a `UIScrollView` un-zoomable outright, on top
    /// of pinning both scale bounds to 1.
    final class ZoomLockDelegate: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }
    }

    func makeCoordinator() -> ZoomLockDelegate { ZoomLockDelegate() }

    func makeUIView(context: Context) -> WKWebView {
        guard let schemeHandler = NovaSchemeHandler() else {
            assertionFailure("Bundled www/ not found — did the prebuild script run?")
            return WKWebView(frame: .zero)
        }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: NovaSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.bouncesZoom = false
        webView.scrollView.delegate = context.coordinator
        webView.load(URLRequest(url: NovaSchemeHandler.appURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
