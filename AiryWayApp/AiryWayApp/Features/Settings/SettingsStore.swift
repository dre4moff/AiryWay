import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ModelCapabilities: Hashable, Codable {
    let supportsFileInput: Bool
    let supportsImageInput: Bool
    let supportsAudioInput: Bool

    static let unavailable = ModelCapabilities(
        supportsFileInput: false,
        supportsImageInput: false,
        supportsAudioInput: false
    )

    static let textOnly = ModelCapabilities(
        supportsFileInput: true,
        supportsImageInput: false,
        supportsAudioInput: false
    )

    static let nativeVision = ModelCapabilities(
        supportsFileInput: true,
        supportsImageInput: true,
        supportsAudioInput: false
    )
}

struct InstalledModel: Identifiable, Hashable {
    let fileURL: URL
    let fileSizeBytes: Int64
    let modifiedAt: Date

    var id: String { fileURL.path }
    var fileName: String { fileURL.lastPathComponent }

    var fileSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var modelPath: String {
        didSet {
            defaults.set(modelPath, forKey: Keys.modelPath)
            let selectedFileName = modelPath.isEmpty ? "" : URL(fileURLWithPath: modelPath).lastPathComponent
            selectedModelCapabilities = capabilitiesForFileName(selectedFileName)
        }
    }
    @Published var maxReaderCharacters: Int {
        didSet { defaults.set(maxReaderCharacters, forKey: Keys.maxReaderCharacters) }
    }
    @Published var maxContextCharacters: Int {
        didSet { defaults.set(maxContextCharacters, forKey: Keys.maxContextCharacters) }
    }
    @Published var appAppearance: AppAppearance {
        didSet { defaults.set(appAppearance.rawValue, forKey: Keys.appAppearance) }
    }
    @Published var computePreference: LocalComputePreference {
        didSet {
            defaults.set(computePreference.rawValue, forKey: Keys.computePreference)
            engine.setComputePreference(computePreference)
            Task { [weak self] in
                await self?.reloadModelForComputePreferenceChangeIfNeeded()
            }
        }
    }
    @Published var safeModeAllowlistEnabled: Bool {
        didSet { defaults.set(safeModeAllowlistEnabled, forKey: Keys.safeModeAllowlistEnabled) }
    }
    @Published var safeModeAllowlistRaw: String {
        didSet { defaults.set(safeModeAllowlistRaw, forKey: Keys.safeModeAllowlistRaw) }
    }

    @Published private(set) var modelState: LocalModelState = .unloaded
    @Published private(set) var installedModels: [InstalledModel] = []
    @Published private(set) var selectedModelCapabilities: ModelCapabilities = .textOnly
    @Published private(set) var cacheEntryCount: Int = 0
    @Published private(set) var cacheApproximateBytes: Int64 = 0

    @Published var modelDownloadURLInput: String = ""
    @Published private(set) var isDownloadingModel = false
    @Published private(set) var modelDownloadProgress: Double = 0
    @Published private(set) var modelDownloadStatusText: String = ""
    @Published private(set) var activeModelDownloadURL: URL?

    @Published private(set) var lastErrorMessage: String?

    private let defaults = UserDefaults.standard
    private let engine: LocalLLMEngine
    private let fetcher = WebPageFetcher()
    private let modelStore = ModelFileStore.shared
    private let downloadService = ModelDownloadService()

    init(engine: LocalLLMEngine = LlamaCppEngine()) {
        self.engine = engine
        modelPath = defaults.string(forKey: Keys.modelPath) ?? ""

        let readerFallback = 12_000
        maxReaderCharacters = defaults.object(forKey: Keys.maxReaderCharacters) as? Int ?? readerFallback

        let contextFallback = 7_000
        maxContextCharacters = defaults.object(forKey: Keys.maxContextCharacters) as? Int ?? contextFallback

        let appearanceRaw = defaults.string(forKey: Keys.appAppearance) ?? AppAppearance.system.rawValue
        appAppearance = AppAppearance(rawValue: appearanceRaw) ?? .system

        let preferenceRaw = defaults.string(forKey: Keys.computePreference) ?? LocalComputePreference.auto.rawValue
        computePreference = LocalComputePreference(rawValue: preferenceRaw) ?? .auto

        safeModeAllowlistEnabled = defaults.object(forKey: Keys.safeModeAllowlistEnabled) as? Bool ?? false
        safeModeAllowlistRaw = defaults.string(forKey: Keys.safeModeAllowlistRaw) ?? ""

        engine.setComputePreference(computePreference)
        let selectedFileName = modelPath.isEmpty ? "" : URL(fileURLWithPath: modelPath).lastPathComponent
        selectedModelCapabilities = capabilitiesForFileName(selectedFileName)
    }

    var selectedEngineName: String { engine.displayName }
    var activeComputeBackendLabel: String { engine.activeComputeBackend.label }
    var isGPUOffloadSupported: Bool { engine.supportsGPUOffload }
    var isNativeImageInputRuntimeAvailable: Bool { engine.supportsNativeImageInput }

    var selectedModelName: String {
        guard !modelPath.isEmpty else { return "No model selected" }
        return URL(fileURLWithPath: modelPath).lastPathComponent
    }

    var selectedModelSizeLabel: String {
        guard let selected = installedModels.first(where: { $0.fileURL.path == modelPath }) else { return "-" }
        return selected.fileSizeLabel
    }

    func capabilitiesForFileName(_ fileName: String) -> ModelCapabilities {
        let normalized = fileName.lowercased()
        if normalized.isEmpty {
            return .unavailable
        }

        let supportsImage = normalized.contains("llava")
            || normalized.contains("vision")
            || normalized.contains("qwen2-vl")
            || normalized.contains("qwen2.5-vl")
            || normalized.contains("gemma-4")
            || normalized.contains("gemma4")
            || normalized.contains("internvl")
            || normalized.contains("moondream")
            || normalized.contains("florence")
            || normalized.contains("janus")

        let supportsAudio = normalized.contains("whisper")
            || normalized.contains("qwen2-audio")
            || normalized.contains("qwen2.5-omni")
            || normalized.contains("audio")

        return ModelCapabilities(
            supportsFileInput: true,
            supportsImageInput: supportsImage,
            supportsAudioInput: supportsAudio
        )
    }

    var cacheApproximateSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: cacheApproximateBytes, countStyle: .file)
    }

    func bootstrap() async {
        await refreshInstalledModels()
        await refreshCacheStats()

        guard !modelPath.isEmpty else {
            modelState = .unloaded
            return
        }

        await loadSelectedModel(silent: true)
    }

    func loadSelectedModel(silent: Bool = false) async {
        guard !modelPath.isEmpty else {
            modelState = .unloaded
            if !silent { lastErrorMessage = "Select a model first." }
            return
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            modelState = .error("model file missing")
            if !silent { lastErrorMessage = "The selected model file no longer exists." }
            return
        }

        modelState = .loading
        do {
            try await engine.loadModel(at: modelURL)
            modelState = .ready
            lastErrorMessage = nil
        } catch {
            modelState = .error(error.localizedDescription)
            if !silent { lastErrorMessage = error.localizedDescription }
        }
    }

    func unloadModel() async {
        engine.stopGeneration()
        await engine.unloadModel()
        modelState = .unloaded
    }

    func generate(
        prompt: String,
        context: String,
        conversation: [ChatMessage] = [],
        onToken: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> LocalModelResponse {
        if engine.loadedModelURL == nil {
            await loadSelectedModel(silent: false)
        }

        guard engine.loadedModelURL != nil else {
            throw LocalLLMError.modelNotLoaded
        }

        modelState = .generating
        do {
            let response = try await engine.generate(
                prompt: prompt,
                context: context,
                conversation: conversation,
                maxOutputTokens: nil,
                onToken: onToken
            )
            modelState = .ready
            return response
        } catch {
            if let llmError = error as? LocalLLMError,
               case .generationCancelled = llmError {
                modelState = .ready
                throw error
            }
            if error is CancellationError {
                modelState = .ready
                throw LocalLLMError.generationCancelled
            }

            modelState = .error(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func stopGeneration() {
        engine.stopGeneration()
        if case .generating = modelState {
            modelState = .ready
        }
    }

    func setLastErrorMessage(_ message: String?) {
        lastErrorMessage = message
    }

    func importModel(from sourceURL: URL) async {
        let hasScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let installed = try await modelStore.importModel(from: sourceURL)
            modelPath = installed.fileURL.path
            await refreshInstalledModels()
            await loadSelectedModel()
            lastErrorMessage = nil
        } catch {
            modelState = .error(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    func downloadModelFromInput() async {
        let candidate = modelDownloadURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteURL = URL(string: candidate),
              let scheme = remoteURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            lastErrorMessage = "Insert a valid HTTP(S) URL for a .gguf model."
            return
        }

        await startDownload(from: remoteURL)
    }

    func downloadModel(from remoteURL: URL) async {
        guard let scheme = remoteURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            lastErrorMessage = "Invalid URL: only HTTP(S) is supported."
            return
        }
        await startDownload(from: remoteURL)
    }

    func cancelModelDownload() {
        downloadService.cancel()
        isDownloadingModel = false
        activeModelDownloadURL = nil
        modelDownloadStatusText = "Download cancelled"
    }

    func useModel(_ model: InstalledModel) async {
        modelPath = model.fileURL.path
        await loadSelectedModel()
    }

    func removeModel(_ model: InstalledModel) async {
        do {
            if model.fileURL.path == modelPath {
                await unloadModel()
                modelPath = ""
            }

            try await modelStore.deleteModel(at: model.fileURL)
            await refreshInstalledModels()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshInstalledModels() async {
        do {
            installedModels = try await modelStore.listModels()
        } catch {
            installedModels = []
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshCacheStats() async {
        let stats = await fetcher.cacheStats()
        cacheEntryCount = stats.entryCount
        cacheApproximateBytes = stats.approximateBytesOnDisk
    }

    func clearPageCache() async {
        await fetcher.clearCache()
        await refreshCacheStats()
    }

    func clearNetworkAndTemporaryCaches() async {
        URLCache.shared.removeAllCachedResponses()
        _ = try? await modelStore.cleanupTemporaryDownloads()
        await refreshCacheStats()
    }

    func isURLAllowedForTools(_ url: URL) -> Bool {
        guard URLInputNormalizer.isWebURLAllowed(url) else { return false }
        guard safeModeAllowlistEnabled else { return true }

        let host = url.host?.lowercased() ?? ""
        let allowlist = parsedAllowlistHosts
        guard !allowlist.isEmpty else { return false }

        for candidate in allowlist {
            if candidate.hasPrefix("*.") {
                let suffix = String(candidate.dropFirst(1))
                if host.hasSuffix(suffix) { return true }
            }
            if host == candidate { return true }
        }

        return false
    }

    private var parsedAllowlistHosts: [String] {
        safeModeAllowlistRaw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func startDownload(from remoteURL: URL) async {
        var attemptedDestination: URL?
        do {
            isDownloadingModel = true
            activeModelDownloadURL = remoteURL
            modelDownloadProgress = 0
            modelDownloadStatusText = "Fetching remote metadata..."
            lastErrorMessage = nil

            let remoteInfo = try await downloadService.fetchRemoteFileInfo(from: remoteURL)
            let destination = try await modelStore.destinationURL(
                forRemoteURL: remoteURL,
                suggestedFileName: remoteInfo.suggestedFileName
            )
            attemptedDestination = destination

            if let expectedBytes = remoteInfo.expectedSizeBytes {
                let requiredBytes = expectedBytes + 1_073_741_824 // model + 1 GB safety margin
                let freeBytes = availableStorageBytes()
                if freeBytes > 0 && freeBytes < requiredBytes {
                    throw LocalLLMError.backend(
                        "Not enough free storage. Needed ~\(formatBytes(requiredBytes)), available \(formatBytes(freeBytes))."
                    )
                }
                modelDownloadStatusText = "Downloading \(remoteInfo.suggestedFileName) (\(formatBytes(expectedBytes)))"
            } else {
                modelDownloadStatusText = "Downloading \(remoteInfo.suggestedFileName)"
            }

            let downloadedURL = try await downloadService.download(from: remoteInfo.finalURL, to: destination) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    modelDownloadProgress = progress
                    modelDownloadStatusText = "Downloading \(Int(progress * 100))%"
                }
            }

            let installed = try await modelStore.validateInstalledModel(
                at: downloadedURL,
                expectedMinimumBytes: expectedMinimumBytes(from: remoteInfo.expectedSizeBytes)
            )
            modelPath = installed.fileURL.path
            modelDownloadStatusText = "Download complete"
            modelDownloadProgress = 1
            await refreshInstalledModels()
            await loadSelectedModel()
        } catch {
            if let attemptedDestination {
                try? await modelStore.deleteModel(at: attemptedDestination)
            }
            modelDownloadStatusText = "Download failed"
            lastErrorMessage = error.localizedDescription
        }

        isDownloadingModel = false
        activeModelDownloadURL = nil
    }

    private func availableStorageBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func expectedMinimumBytes(from expected: Int64?) -> Int64? {
        guard let expected, expected > 0 else { return nil }
        // tolerate minor differences in Content-Length/accounting, but reject strongly partial files.
        let tolerance = min(expected / 50, Int64(32 * 1_048_576)) // max 2%
        return max(0, expected - tolerance)
    }

    private func reloadModelForComputePreferenceChangeIfNeeded() async {
        guard engine.loadedModelURL != nil else { return }
        if case .generating = modelState { return }
        await loadSelectedModel(silent: true)
    }

    private enum Keys {
        static let modelPath = "airyway.settings.modelPath"
        static let maxReaderCharacters = "airyway.settings.maxReaderCharacters"
        static let maxContextCharacters = "airyway.settings.maxContextCharacters"
        static let appAppearance = "airyway.settings.appAppearance"
        static let computePreference = "airyway.settings.computePreference"
        static let safeModeAllowlistEnabled = "airyway.settings.safeModeAllowlistEnabled"
        static let safeModeAllowlistRaw = "airyway.settings.safeModeAllowlistRaw"
    }
}

actor ModelFileStore {
    static let shared = ModelFileStore()

    private let modelsDirectoryURL: URL
    private let tempDirectoryURL: URL

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        modelsDirectoryURL = support.appendingPathComponent("AiryWay/Models", isDirectory: true)
        tempDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent("AiryWayModelDownloads", isDirectory: true)

        try? fileManager.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    func importModel(from sourceURL: URL) throws -> InstalledModel {
        let fileManager = FileManager.default
        guard sourceURL.pathExtension.lowercased() == "gguf" else {
            throw LocalLLMError.unsupportedModelExtension
        }

        let destination = uniqueDestinationURL(for: sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return try validateInstalledModel(at: destination)
    }

    func destinationURL(forRemoteURL remoteURL: URL, suggestedFileName: String? = nil) throws -> URL {
        let fromSuggestion = suggestedFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidateName: String
        if !fromSuggestion.isEmpty {
            candidateName = fromSuggestion
        } else if !remoteURL.lastPathComponent.isEmpty {
            candidateName = remoteURL.lastPathComponent
        } else {
            candidateName = "downloaded-model.gguf"
        }

        let decodedName = candidateName.removingPercentEncoding ?? candidateName
        let normalizedName = (decodedName as NSString).lastPathComponent

        guard normalizedName.lowercased().hasSuffix(".gguf") else {
            throw LocalLLMError.unsupportedModelExtension
        }
        return uniqueDestinationURL(for: normalizedName)
    }

    func validateInstalledModel(at fileURL: URL, expectedMinimumBytes: Int64? = nil) throws -> InstalledModel {
        let fileManager = FileManager.default
        guard fileURL.pathExtension.lowercased() == "gguf" else {
            throw LocalLLMError.unsupportedModelExtension
        }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteSize > 0 else {
            throw LocalLLMError.invalidModelPath
        }
        if let expectedMinimumBytes, byteSize < expectedMinimumBytes {
            throw LocalLLMError.backend(
                "Downloaded file appears incomplete (\(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)))."
            )
        }
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        return InstalledModel(fileURL: fileURL, fileSizeBytes: byteSize, modifiedAt: modified)
    }

    func listModels() throws -> [InstalledModel] {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: modelsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var models: [InstalledModel] = []
        models.reserveCapacity(files.count)

        for file in files where file.pathExtension.lowercased() == "gguf" {
            if let model = try? validateInstalledModel(at: file) {
                models.append(model)
            }
        }

        return models.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func deleteModel(at fileURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    func cleanupTemporaryDownloads() throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: tempDirectoryURL.path) else { return 0 }
        let urls = try fileManager.contentsOfDirectory(at: tempDirectoryURL, includingPropertiesForKeys: nil)
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
        return urls.count
    }

    private func uniqueDestinationURL(for proposedName: String) -> URL {
        let fileManager = FileManager.default
        let safeName = proposedName.replacingOccurrences(of: "/", with: "_")
        let baseName = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension

        var candidate = modelsDirectoryURL.appendingPathComponent(safeName)
        var index = 1

        while fileManager.fileExists(atPath: candidate.path) {
            let fileName = "\(baseName)-\(index).\(ext)"
            candidate = modelsDirectoryURL.appendingPathComponent(fileName)
            index += 1
        }

        return candidate
    }
}

struct RemoteModelFileInfo {
    let finalURL: URL
    let suggestedFileName: String
    let expectedSizeBytes: Int64?
}

final class ModelDownloadService: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var destinationURL: URL?
    private var progressHandler: ((Double) -> Void)?
    private var activeTask: URLSessionDownloadTask?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    deinit {
        session.invalidateAndCancel()
    }

    func fetchRemoteFileInfo(from remoteURL: URL) async throws -> RemoteModelFileInfo {
        var head = URLRequest(url: remoteURL)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 45
        head.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: head)
            return try parseRemoteInfo(from: response, sourceURL: remoteURL)
        } catch {
            // Some hosts reject HEAD: use byte-range GET to collect metadata only.
            var ranged = URLRequest(url: remoteURL)
            ranged.httpMethod = "GET"
            ranged.timeoutInterval = 45
            ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            ranged.cachePolicy = .reloadIgnoringLocalCacheData
            let (_, response) = try await session.data(for: ranged)
            return try parseRemoteInfo(from: response, sourceURL: remoteURL)
        }
    }

    func download(from remoteURL: URL, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard activeTask == nil else {
            throw LocalLLMError.downloadInProgress
        }

        self.destinationURL = destinationURL
        progressHandler = progress

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 120
            let task = session.downloadTask(with: request)
            activeTask = task
            task.resume()
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(max(0, min(progress, 1)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destinationURL else {
            finish(with: .failure(LocalLLMError.invalidModelPath))
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            finish(with: .success(destinationURL))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<URL, Error>) {
        guard let continuation else { return }

        self.continuation = nil
        destinationURL = nil
        progressHandler = nil
        activeTask = nil

        switch result {
        case let .success(url):
            continuation.resume(returning: url)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func parseRemoteInfo(from response: URLResponse, sourceURL: URL) throws -> RemoteModelFileInfo {
        guard let http = response as? HTTPURLResponse else {
            throw LocalLLMError.backend("Unexpected response while fetching model metadata.")
        }

        guard (200 ... 299).contains(http.statusCode) || http.statusCode == 206 else {
            throw LocalLLMError.backend("Model endpoint returned HTTP \(http.statusCode).")
        }

        let resolvedURL = response.url ?? sourceURL
        let fileName = suggestedFileName(from: http, fallbackURL: resolvedURL)
        guard fileName.lowercased().hasSuffix(".gguf") else {
            throw LocalLLMError.unsupportedModelExtension
        }

        return RemoteModelFileInfo(
            finalURL: resolvedURL,
            suggestedFileName: fileName,
            expectedSizeBytes: expectedSizeBytes(from: http, response: response)
        )
    }

    private func suggestedFileName(from response: HTTPURLResponse, fallbackURL: URL) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = parseFileName(fromContentDisposition: disposition) {
            let decoded = parsed.removingPercentEncoding ?? parsed
            return (decoded as NSString).lastPathComponent
        }

        if let suggested = response.suggestedFilename, !suggested.isEmpty {
            return suggested
        }

        let fallback = fallbackURL.lastPathComponent
        return fallback.isEmpty ? "downloaded-model.gguf" : fallback
    }

    private func parseFileName(fromContentDisposition value: String) -> String? {
        let fields = value
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let utfField = fields.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
            let raw = String(utfField.dropFirst("filename*=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let marker = raw.range(of: "''") {
                return String(raw[marker.upperBound...])
            }
            return raw
        }

        if let basicField = fields.first(where: { $0.lowercased().hasPrefix("filename=") }) {
            return String(basicField.dropFirst("filename=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        return nil
    }

    private func expectedSizeBytes(from response: HTTPURLResponse, response urlResponse: URLResponse) -> Int64? {
        if urlResponse.expectedContentLength > 0 {
            return urlResponse.expectedContentLength
        }

        if let linkedSize = response.value(forHTTPHeaderField: "X-Linked-Size"),
           let value = Int64(linkedSize),
           value > 0 {
            return value
        }

        if let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let value = Int64(contentLength),
           value > 0 {
            return value
        }

        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let suffix = contentRange[contentRange.index(after: slash)...]
            if let value = Int64(suffix), value > 0 {
                return value
            }
        }

        return nil
    }
}
