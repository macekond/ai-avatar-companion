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
    ///
    /// Also removes WKWebView's built-in `UIDragInteraction` once the page
    /// loads (see `disableDragInteractions`) — holding down `#ptt-btn` was
    /// silently losing the gesture to it, which no amount of
    /// `touch-action`/`-webkit-user-drag` CSS could prevent since the
    /// interaction lives on WKWebView's native content view, not anything
    /// CSS reaches. Reported as "hold to talk does nothing, conversation
    /// can't continue" — the client-side cause the 20s PTT watchdog in
    /// main.js was only ever a band-aid for.
    final class Coordinator: NSObject, UIScrollViewDelegate, WKNavigationDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.disableDragInteractions(in: webView)
        }

        static func disableDragInteractions(in view: UIView) {
            for interaction in view.interactions where interaction is UIDragInteraction {
                view.removeInteraction(interaction)
            }
            for subview in view.subviews {
                disableDragInteractions(in: subview)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: NovaSchemeHandler.appURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
