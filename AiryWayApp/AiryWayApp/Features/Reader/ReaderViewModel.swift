import Foundation

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var urlText: String = "https://www.apple.com"
    @Published var pageTitle: String = ""
    @Published var pageText: String = ""
    @Published var textChunks: [String] = []
    @Published var sourceLabel: String = ""
    @Published var rawHTML: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    let fetcher = WebPageFetcher()
    var lastFetchedURL: URL?

    func fetch(maxCharacters: Int, forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await fetcher.fetch(
                urlString: urlText,
                forceRefresh: forceRefresh,
                maxChunkSize: min(maxCharacters, 3500)
            )
            update(with: result, maxCharacters: maxCharacters)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(with result: FetchResult, maxCharacters: Int) {
        pageTitle = result.title
        pageText = String(result.plainText.prefix(maxCharacters))
        textChunks = HTMLTextExtractor.chunk(text: pageText, maxChunkSize: min(maxCharacters, 3500))
        rawHTML = result.html
        sourceLabel = result.source == .cache ? "Cache" : "Network"
        lastFetchedURL = result.finalURL ?? result.url
        urlText = lastFetchedURL?.absoluteString ?? result.url.absoluteString
    }
}
