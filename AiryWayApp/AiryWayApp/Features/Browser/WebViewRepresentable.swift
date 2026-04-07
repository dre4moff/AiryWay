import SwiftUI
import WebKit

struct WebViewRepresentable: UIViewRepresentable {
    @EnvironmentObject private var browserStore: BrowserStore

    func makeCoordinator() -> Coordinator { Coordinator(browserStore: browserStore) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        browserStore.attach(webView: webView)

        if browserStore.currentURL == nil {
            browserStore.loadAddressBar()
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let browserStore: BrowserStore

        init(browserStore: BrowserStore) {
            self.browserStore = browserStore
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in self.browserStore.syncState(from: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.browserStore.syncState(from: webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in self.browserStore.syncState(from: webView) }
        }
    }
}
