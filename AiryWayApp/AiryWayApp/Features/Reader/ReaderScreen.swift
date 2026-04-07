import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin

struct ModelHubScreen: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var isImporterPresented = false
    @State private var deviceProfile = DeviceProfile.current()
    @State private var models: [DownloadableModel] = []
    @State private var isLoadingCatalog = false
    @State private var catalogErrorMessage: String?

    private let catalogService = RemoteModelCatalogService()

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                .ignoresSafeArea()

                Form {
                    Section("This iPhone") {
                        LabeledContent("Model", value: deviceProfile.hardwareIdentifier)
                        LabeledContent("RAM", value: String(format: "%.1f GB", deviceProfile.ramGB))
                        LabeledContent("Free storage", value: String(format: "%.1f GB", deviceProfile.freeStorageGB))
                        Button("Refresh device info") {
                            deviceProfile = DeviceProfile.current()
                        }
                    }

                    Section("Recommended models (online)") {
                        if isLoadingCatalog && models.isEmpty {
                            ProgressView("Fetching catalog...")
                        } else if models.isEmpty {
                            Text(catalogErrorMessage ?? "No compatible models available right now.")
                                .foregroundStyle(.secondary)
                            Button("Retry") {
                                Task { await refreshCatalog() }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            ForEach(models) { model in
                                let installedModel = installedModel(for: model)
                                let isDownloadingThisModel = settingsStore.isDownloadingModel
                                    && settingsStore.activeModelDownloadURL?.absoluteString == model.downloadURL.absoluteString

                                ModelCard(
                                    model: model,
                                    compatibility: deviceProfile.compatibility(for: model),
                                    installedModel: installedModel,
                                    selectedModelPath: settingsStore.modelPath,
                                    isDownloadingThisModel: isDownloadingThisModel,
                                    downloadProgress: settingsStore.modelDownloadProgress,
                                    downloadStatusText: settingsStore.modelDownloadStatusText,
                                    downloadAction: {
                                        Task { await settingsStore.downloadModel(from: model.downloadURL) }
                                    },
                                    cancelDownloadAction: {
                                        settingsStore.cancelModelDownload()
                                    },
                                    useAction: {
                                        guard let installedModel else { return }
                                        Task { await settingsStore.useModel(installedModel) }
                                    },
                                    deleteAction: {
                                        guard let installedModel else { return }
                                        Task { await settingsStore.removeModel(installedModel) }
                                    }
                                )
                            }
                        }
                    }

                    Section("Manual import") {
                        Button("Import GGUF from Files") {
                            isImporterPresented = true
                        }
                        .buttonStyle(.bordered)
                    }

                    Section("Other installed models") {
                        let others = otherInstalledModelsNotInCatalog()
                        if others.isEmpty {
                            Text("No extra installed models.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(others) { model in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.fileName)
                                            .font(.callout.weight(.semibold))
                                        Text(model.fileSizeLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ModelCapabilitiesRow(
                                            capabilities: settingsStore.capabilitiesForFileName(model.fileName)
                                        )
                                    }
                                    Spacer()
                                    Button("Use") {
                                        Task { await settingsStore.useModel(model) }
                                    }
                                    .buttonStyle(.bordered)
                                    Button(role: .destructive) {
                                        Task { await settingsStore.removeModel(model) }
                                    } label: {
                                        Text("Delete")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    if let error = settingsStore.lastErrorMessage, !error.isEmpty {
                        Section("Last error") {
                            Text(error)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshCatalog() }
                    } label: {
                        if isLoadingCatalog {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoadingCatalog)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let first = urls.first else { return }
            Task { await settingsStore.importModel(from: first) }
        }
        .task {
            await refreshCatalog()
            await settingsStore.refreshInstalledModels()
            deviceProfile = DeviceProfile.current()
        }
    }

    private var backgroundGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.14),
                    Color(red: 0.10, green: 0.13, blue: 0.19),
                    Color(red: 0.06, green: 0.07, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.97, blue: 1.0),
                Color(red: 0.92, green: 0.95, blue: 0.99),
                Color.white
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func refreshCatalog() async {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        catalogErrorMessage = nil
        defer { isLoadingCatalog = false }

        do {
            models = try await catalogService.fetchCatalog()
        } catch {
            models = []
            catalogErrorMessage = error.localizedDescription
        }
    }

    private func installedModel(for downloadableModel: DownloadableModel) -> InstalledModel? {
        let targetStem = ((downloadableModel.fileName as NSString).deletingPathExtension).lowercased()
        return settingsStore.installedModels.first { installed in
            let stem = ((installed.fileName as NSString).deletingPathExtension).lowercased()
            return stem == targetStem || stem.hasPrefix(targetStem + "-")
        }
    }

    private func otherInstalledModelsNotInCatalog() -> [InstalledModel] {
        let mappedIDs = Set(models.compactMap { model -> String? in
            installedModel(for: model)?.id
        })
        return settingsStore.installedModels.filter { !mappedIDs.contains($0.id) }
    }
}

private struct ModelCard: View {
    let model: DownloadableModel
    let compatibility: ModelCompatibility
    let installedModel: InstalledModel?
    let selectedModelPath: String
    let isDownloadingThisModel: Bool
    let downloadProgress: Double
    let downloadStatusText: String
    let downloadAction: () -> Void
    let cancelDownloadAction: () -> Void
    let useAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.name)
                .font(.headline)
            Text("\(model.sizeLabel) • \(model.quantization)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.repositoryID)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Min RAM: \(String(format: "%.1f", model.minRAMGB)) GB")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ModelCapabilitiesRow(capabilities: model.capabilities)

            if let installedModel {
                Label("Installed • \(installedModel.fileSizeLabel)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)

                HStack(spacing: 8) {
                    Button(isSelected(installedModel) ? "Selected" : "Use") {
                        useAction()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSelected(installedModel))

                    Button(role: .destructive) {
                        deleteAction()
                    } label: {
                        Text("Delete")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                switch compatibility {
                case .compatible:
                    Label("Compatible", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case let .notCompatible(reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if isDownloadingThisModel {
                    ProgressView(value: downloadProgress) {
                        Text(downloadStatusText)
                    }
                    Button("Cancel download") {
                        cancelDownloadAction()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Download") {
                        downloadAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!compatibility.isCompatible)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func isSelected(_ model: InstalledModel) -> Bool {
        model.fileURL.path == selectedModelPath
    }
}

private struct ModelCapabilitiesRow: View {
    let capabilities: ModelCapabilities

    var body: some View {
        HStack(spacing: 10) {
            capabilityTag(
                title: "File",
                icon: "doc.text",
                supported: capabilities.supportsFileInput
            )
            capabilityTag(
                title: "Image",
                icon: "photo",
                supported: capabilities.supportsImageInput
            )
            capabilityTag(
                title: "Audio",
                icon: "waveform",
                supported: capabilities.supportsAudioInput
            )
        }
    }

    @ViewBuilder
    private func capabilityTag(title: String, icon: String, supported: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(supported ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
        )
        .foregroundStyle(supported ? Color.green : Color.secondary)
    }
}

private struct DownloadableModel: Identifiable {
    let id: String
    let name: String
    let repositoryID: String
    let fileName: String
    let quantization: String
    let fileSizeBytes: Int64
    let minRAMGB: Double
    let downloadURL: URL
    let capabilities: ModelCapabilities

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var sizeGB: Double {
        Double(fileSizeBytes) / 1_073_741_824
    }
}

private enum ModelCompatibility {
    case compatible
    case notCompatible(String)

    var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }
}

private struct DeviceProfile {
    let hardwareIdentifier: String
    let ramGB: Double
    let freeStorageGB: Double

    static func current() -> DeviceProfile {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let resourceValues = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let freeBytes = Double(resourceValues?.volumeAvailableCapacityForImportantUsage ?? 0)
        let freeStorage = freeBytes / 1_073_741_824

        return DeviceProfile(
            hardwareIdentifier: UIDevice.current.hardwareIdentifier,
            ramGB: ram,
            freeStorageGB: freeStorage
        )
    }

    func compatibility(for model: DownloadableModel) -> ModelCompatibility {
        var reasons: [String] = []

        if ramGB < model.minRAMGB {
            reasons.append("Needs >= \(String(format: "%.1f", model.minRAMGB)) GB RAM")
        }

        let minFreeStorage = model.sizeGB + 2.0
        if freeStorageGB < minFreeStorage {
            reasons.append("Needs >= \(String(format: "%.1f", minFreeStorage)) GB free storage")
        }

        if reasons.isEmpty {
            return .compatible
        }

        return .notCompatible(reasons.joined(separator: " • "))
    }
}

private final class RemoteModelCatalogService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchCatalog() async throws -> [DownloadableModel] {
        var loaded: [DownloadableModel] = []
        var firstError: Error?

        await withTaskGroup(of: Result<DownloadableModel, Error>.self) { group in
            for seed in Self.seedCatalog {
                group.addTask { [session] in
                    do {
                        return .success(try await Self.fetchModel(seed: seed, session: session))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for await result in group {
                switch result {
                case let .success(model):
                    loaded.append(model)
                case let .failure(error):
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }

        if loaded.isEmpty {
            throw firstError ?? ModelCatalogError.noModelsAvailable
        }

        return loaded.sorted {
            if $0.minRAMGB == $1.minRAMGB {
                return $0.fileSizeBytes < $1.fileSizeBytes
            }
            return $0.minRAMGB < $1.minRAMGB
        }
    }

    private static func fetchModel(seed: ModelSeed, session: URLSession) async throws -> DownloadableModel {
        guard let apiURL = modelAPIURL(for: seed.repositoryID) else {
            throw ModelCatalogError.invalidSeed(seed.name)
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.unexpectedResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ModelCatalogError.http(http.statusCode)
        }

        let payload = try JSONDecoder().decode(HFModelResponse.self, from: data)
        guard let siblings = payload.siblings, !siblings.isEmpty else {
            throw ModelCatalogError.noGGUFInRepository(seed.repositoryID)
        }

        let preferred = Set(seed.preferredFileNames.map { $0.lowercased() })
        let selected = siblings.first(where: { preferred.contains($0.rfilename.lowercased()) }) ??
            siblings.first(where: { $0.rfilename.lowercased().hasSuffix(".gguf") })

        guard let selected else {
            throw ModelCatalogError.noGGUFInRepository(seed.repositoryID)
        }

        let fileSize = selected.size ?? selected.lfs?.size ?? 0
        guard fileSize > 0 else {
            throw ModelCatalogError.missingFileSize(selected.rfilename)
        }

        guard let downloadURL = downloadURL(repositoryID: seed.repositoryID, fileName: selected.rfilename) else {
            throw ModelCatalogError.invalidSeed(seed.name)
        }

        return DownloadableModel(
            id: "\(seed.repositoryID)#\(selected.rfilename)",
            name: seed.name,
            repositoryID: seed.repositoryID,
            fileName: selected.rfilename,
            quantization: quantizationLabel(from: selected.rfilename),
            fileSizeBytes: fileSize,
            minRAMGB: seed.minRAMGB,
            downloadURL: downloadURL,
            capabilities: seed.capabilities
        )
    }

    private static func quantizationLabel(from fileName: String) -> String {
        let withoutExtension = (fileName as NSString).deletingPathExtension
        let components = withoutExtension.split(separator: "-")
        guard let last = components.last else { return "GGUF" }
        return String(last)
    }

    private static func modelAPIURL(for repositoryID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.percentEncodedPath = "/api/models/\(repositoryID)"
        components.queryItems = [
            URLQueryItem(name: "blobs", value: "true")
        ]
        return components.url
    }

    private static func downloadURL(repositoryID: String, fileName: String) -> URL? {
        let encodedFile = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        return URL(string: "https://huggingface.co/\(repositoryID)/resolve/main/\(encodedFile)")
    }

    private static let seedCatalog: [ModelSeed] = [
        ModelSeed(
            name: "Moondream2 Vision",
            repositoryID: "moondream/moondream2-gguf",
            preferredFileNames: ["moondream2-text-model-f16.gguf"],
            minRAMGB: 4.0,
            capabilities: .nativeVision
        ),
        ModelSeed(
            name: "Qwen2.5 VL 3B Instruct",
            repositoryID: "unsloth/Qwen2.5-VL-3B-Instruct-GGUF",
            preferredFileNames: ["Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf"],
            minRAMGB: 8.0,
            capabilities: .nativeVision
        ),
        ModelSeed(
            name: "LLaVA Llama 3 8B v1.1",
            repositoryID: "xtuner/llava-llama-3-8b-v1_1-gguf",
            preferredFileNames: ["llava-llama-3-8b-v1_1-int4.gguf"],
            minRAMGB: 10.0,
            capabilities: .nativeVision
        ),
        ModelSeed(
            name: "Qwen2.5 0.5B Instruct",
            repositoryID: "bartowski/Qwen2.5-0.5B-Instruct-GGUF",
            preferredFileNames: ["Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"],
            minRAMGB: 3.0,
            capabilities: .textOnly
        ),
        ModelSeed(
            name: "Qwen2.5 1.5B Instruct",
            repositoryID: "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
            preferredFileNames: ["Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"],
            minRAMGB: 4.0,
            capabilities: .textOnly
        ),
        ModelSeed(
            name: "Llama 3.2 1B Instruct",
            repositoryID: "bartowski/Llama-3.2-1B-Instruct-GGUF",
            preferredFileNames: ["Llama-3.2-1B-Instruct-Q4_K_M.gguf"],
            minRAMGB: 4.0,
            capabilities: .textOnly
        ),
        ModelSeed(
            name: "Gemma 4 E2B Instruct",
            repositoryID: "bartowski/google_gemma-4-E2B-it-GGUF",
            preferredFileNames: ["google_gemma-4-E2B-it-Q4_K_M.gguf"],
            minRAMGB: 8.0,
            capabilities: .textOnly
        ),
        ModelSeed(
            name: "Phi 3.5 Mini Instruct",
            repositoryID: "bartowski/Phi-3.5-mini-instruct-GGUF",
            preferredFileNames: ["Phi-3.5-mini-instruct-Q4_K_M.gguf"],
            minRAMGB: 6.0,
            capabilities: .textOnly
        ),
        ModelSeed(
            name: "Gemma 4 E4B Instruct",
            repositoryID: "bartowski/google_gemma-4-E4B-it-GGUF",
            preferredFileNames: ["google_gemma-4-E4B-it-Q4_K_M.gguf"],
            minRAMGB: 10.0,
            capabilities: .textOnly
        ),
        ModelSeed(
            name: "Llama 3.2 3B Instruct",
            repositoryID: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            preferredFileNames: ["Llama-3.2-3B-Instruct-Q4_K_M.gguf"],
            minRAMGB: 6.0,
            capabilities: .textOnly
        ),
        ModelSeed(
            name: "Mistral 7B Instruct v0.3",
            repositoryID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
            preferredFileNames: ["Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"],
            minRAMGB: 8.0,
            capabilities: .textOnly
        )
    ]
}

private struct ModelSeed {
    let name: String
    let repositoryID: String
    let preferredFileNames: [String]
    let minRAMGB: Double
    let capabilities: ModelCapabilities
}

private struct HFModelResponse: Decodable {
    let siblings: [HFSibling]?
}

private struct HFSibling: Decodable {
    let rfilename: String
    let size: Int64?
    let lfs: HFLFS?
}

private struct HFLFS: Decodable {
    let size: Int64?
}

private enum ModelCatalogError: LocalizedError {
    case noModelsAvailable
    case noGGUFInRepository(String)
    case missingFileSize(String)
    case invalidSeed(String)
    case http(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .noModelsAvailable:
            return "Online catalog is unavailable. Pull to retry."
        case let .noGGUFInRepository(repo):
            return "No GGUF files found in \(repo)."
        case let .missingFileSize(file):
            return "Missing remote size for \(file)."
        case let .invalidSeed(name):
            return "Invalid model catalog seed: \(name)."
        case let .http(code):
            return "Catalog server error (HTTP \(code))."
        case .unexpectedResponse:
            return "Unexpected catalog response."
        }
    }
}

private extension UIDevice {
    var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
