import Foundation
import WebKit

@MainActor
final class BrowserStore: ObservableObject {
    @Published var addressBarText: String = "https://www.apple.com"
    @Published var currentURL: URL?
    @Published var title: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var recentURLs: [URL] = []

    private let recentURLsKey = "airyway.browser.recentURLs"
    private let maxRecentURLs = 20

    weak var webView: WKWebView?

    init() {
        loadPersistedRecentURLs()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        syncState(from: webView)
    }

    func loadAddressBar() {
        load(input: addressBarText)
    }

    func load(input: String) {
        guard let url = URLInputNormalizer.url(from: input), URLInputNormalizer.isWebURLAllowed(url) else { return }
        addressBarText = url.absoluteString
        currentURL = url
        remember(url)
        webView?.load(URLRequest(url: url))
    }

    func syncState(from webView: WKWebView) {
        title = webView.title ?? ""
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let url = webView.url, URLInputNormalizer.isWebURLAllowed(url) {
            addressBarText = url.absoluteString
            remember(url)
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }

    func clearRecentHistory() {
        recentURLs = []
        UserDefaults.standard.removeObject(forKey: recentURLsKey)
    }

    private func remember(_ url: URL) {
        guard URLInputNormalizer.isWebURLAllowed(url) else { return }
        recentURLs.removeAll { $0.absoluteString == url.absoluteString }
        recentURLs.insert(url, at: 0)
        if recentURLs.count > maxRecentURLs {
            recentURLs = Array(recentURLs.prefix(maxRecentURLs))
        }
        persistRecentURLs()
    }

    private func persistRecentURLs() {
        let values = recentURLs.map(\.absoluteString)
        UserDefaults.standard.set(values, forKey: recentURLsKey)
    }

    private func loadPersistedRecentURLs() {
        let values = UserDefaults.standard.stringArray(forKey: recentURLsKey) ?? []
        recentURLs = values.compactMap { URL(string: $0) }.filter(URLInputNormalizer.isWebURLAllowed)
    }
}
