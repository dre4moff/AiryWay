import Foundation

enum FetchSource: String {
    case network
    case cache
}

struct FetchResult {
    let url: URL
    let finalURL: URL?
    let title: String
    let plainText: String
    let html: String
    let metaDescription: String?
    let chunks: [String]
    let fetchedAt: Date
    let source: FetchSource
}

struct PageCacheStats {
    let entryCount: Int
    let totalCharacters: Int
    let approximateBytesOnDisk: Int64
}

enum WebFetchError: LocalizedError {
    case badURL
    case invalidResponse
    case unsupportedMimeType
    case nonHTTPScheme
    case badStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid URL."
        case .invalidResponse:
            return "The response was invalid."
        case .unsupportedMimeType:
            return "Only HTML pages are supported by the reader."
        case .nonHTTPScheme:
            return "Only HTTP(S) URLs are allowed."
        case let .badStatusCode(code):
            return "HTTP request failed with status code \(code)."
        }
    }
}

final class WebPageFetcher {
    private let session: URLSession
    private let cacheStore: PageCacheStore

    init(session: URLSession = .shared, cacheStore: PageCacheStore = .shared) {
        self.session = session
        self.cacheStore = cacheStore
    }

    func fetch(urlString: String, forceRefresh: Bool = false, maxChunkSize: Int = 3500) async throws -> FetchResult {
        guard let normalizedURL = URLInputNormalizer.url(from: urlString) else {
            throw WebFetchError.badURL
        }
        guard URLInputNormalizer.isWebURLAllowed(normalizedURL) else {
            throw WebFetchError.nonHTTPScheme
        }

        if !forceRefresh, let cached = await cacheStore.cachedResult(for: normalizedURL) {
            return cached
        }

        var request = URLRequest(url: normalizedURL)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebFetchError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            throw WebFetchError.badStatusCode(http.statusCode)
        }

        let mimeType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard mimeType.contains("text/html") || mimeType.contains("application/xhtml+xml") || mimeType.isEmpty else {
            throw WebFetchError.unsupportedMimeType
        }

        let html = String(decoding: data, as: UTF8.self)
        let extracted = await Task.detached(priority: .userInitiated) {
            HTMLTextExtractor.extractContent(from: html, maxChunkSize: maxChunkSize)
        }.value

        let result = FetchResult(
            url: normalizedURL,
            finalURL: response.url,
            title: extracted.title,
            plainText: extracted.combinedText,
            html: html,
            metaDescription: extracted.metaDescription,
            chunks: extracted.chunks,
            fetchedAt: Date(),
            source: .network
        )

        await cacheStore.save(result: result)
        return result
    }

    func cacheStats() async -> PageCacheStats {
        await cacheStore.stats()
    }

    func clearCache() async {
        await cacheStore.clear()
    }
}

actor PageCacheStore {
    static let shared = PageCacheStore()

    private let maxEntries = 20
    private let cacheFileURL: URL
    private var records: [CachedPageRecord] = []

    init() {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let folderURL = supportDirectory.appendingPathComponent("AiryWay/PageCache", isDirectory: true)

        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        cacheFileURL = folderURL.appendingPathComponent("page_cache.json")
        records = Self.readRecords(from: cacheFileURL, maxEntries: maxEntries)
    }

    func cachedResult(for url: URL) -> FetchResult? {
        guard let index = records.firstIndex(where: { $0.urlString == url.absoluteString }) else { return nil }

        records[index].lastAccessed = Date()
        let record = records[index]
        persist()

        return FetchResult(
            url: URL(string: record.urlString) ?? url,
            finalURL: record.finalURLString.flatMap(URL.init(string:)),
            title: record.title,
            plainText: record.plainText,
            html: record.html,
            metaDescription: record.metaDescription,
            chunks: record.chunks,
            fetchedAt: record.fetchedAt,
            source: .cache
        )
    }

    func save(result: FetchResult) {
        let key = result.finalURL?.absoluteString ?? result.url.absoluteString
        records.removeAll { ($0.finalURLString ?? $0.urlString) == key || $0.urlString == result.url.absoluteString }

        records.insert(
            CachedPageRecord(
                urlString: result.url.absoluteString,
                finalURLString: result.finalURL?.absoluteString,
                title: result.title,
                plainText: result.plainText,
                html: result.html,
                metaDescription: result.metaDescription,
                chunks: result.chunks,
                fetchedAt: result.fetchedAt,
                lastAccessed: Date()
            ),
            at: 0
        )

        if records.count > maxEntries {
            records = Array(records.prefix(maxEntries))
        }

        persist()
    }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: cacheFileURL)
    }

    func stats() -> PageCacheStats {
        let characters = records.reduce(0) { $0 + $1.plainText.count }
        let bytes = (try? JSONEncoder().encode(records).count).map(Int64.init) ?? 0
        return PageCacheStats(entryCount: records.count, totalCharacters: characters, approximateBytesOnDisk: bytes)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    private static func readRecords(from fileURL: URL, maxEntries: Int) -> [CachedPageRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CachedPageRecord].self, from: data) else {
            return []
        }
        return Array(decoded.sorted { $0.lastAccessed > $1.lastAccessed }.prefix(maxEntries))
    }
}

private struct CachedPageRecord: Codable {
    let urlString: String
    let finalURLString: String?
    let title: String
    let plainText: String
    let html: String
    let metaDescription: String?
    let chunks: [String]
    let fetchedAt: Date
    var lastAccessed: Date
}
