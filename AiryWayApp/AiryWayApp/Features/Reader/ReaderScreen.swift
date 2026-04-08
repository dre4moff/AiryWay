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

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        HubSectionHeader(title: "This iPhone", subtitle: "Compatibility is calculated using RAM and free storage.") {
                            DeviceProfileCard(
                                deviceProfile: deviceProfile,
                                refreshAction: { deviceProfile = DeviceProfile.current() }
                            )
                        }

                        HubSectionHeader(title: "Installed models", subtitle: "Ready to use now") {
                            if installedModelsSorted.isEmpty {
                                EmptyStateCard(message: "No installed models yet.")
                            } else {
                                ForEach(installedModelsSorted) { installed in
                                    InstalledModelCard(
                                        model: installed,
                                        selectedModelPath: settingsStore.modelPath,
                                        capabilities: installedCapabilities(for: installed),
                                        useAction: {
                                            Task { await settingsStore.useModel(installed) }
                                        },
                                        deleteAction: {
                                            Task { await settingsStore.removeModel(installed) }
                                        }
                                    )
                                    .id(installed.id)
                                }
                            }
                        }

                        HubSectionHeader(title: "Available models (online)", subtitle: "Recommended for this device") {
                            if isLoadingCatalog && availableCatalogModels.isEmpty {
                                LoadingStateCard(title: "Fetching model catalog...")
                            } else if availableCatalogModels.isEmpty {
                                if models.isEmpty {
                                    EmptyStateCard(message: catalogErrorMessage ?? "No compatible models available right now.")
                                    Button("Retry") {
                                        Task { await refreshCatalog() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    EmptyStateCard(message: "All catalog models are already installed.")
                                }
                            } else {
                                ForEach(availableCatalogModels) { model in
                                    let isDownloadingThisModel = settingsStore.isDownloadingModel
                                        && settingsStore.activeModelDownloadURL?.absoluteString == model.downloadURL.absoluteString

                                    ModelCard(
                                        model: model,
                                        compatibility: deviceProfile.compatibility(for: model),
                                        isDownloadingThisModel: isDownloadingThisModel,
                                        downloadProgress: settingsStore.modelDownloadProgress,
                                        downloadStatusText: settingsStore.modelDownloadStatusText,
                                        downloadAction: {
                                            Task { await settingsStore.downloadModel(from: model.downloadURL) }
                                        },
                                        cancelDownloadAction: {
                                            settingsStore.cancelModelDownload()
                                        }
                                    )
                                    .id(model.id)
                                }
                            }
                        }

                        HubSectionHeader(title: "Manual import", subtitle: "Use local GGUF files from Files app") {
                            Button("Import GGUF from Files") {
                                isImporterPresented = true
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if let error = settingsStore.lastErrorMessage, !error.isEmpty {
                            HubSectionHeader(title: "Last error") {
                                ErrorStateCard(message: error)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await reloadAll()
                }
                .animation(.snappy(duration: 0.34, extraBounce: 0.03), value: settingsStore.installedModels.map(\.id))
                .animation(.smooth(duration: 0.25), value: availableCatalogModels.map(\.id))
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
            await reloadAll()
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

    private func reloadAll() async {
        await refreshCatalog()
        await settingsStore.refreshInstalledModels()
        deviceProfile = DeviceProfile.current()
    }

    private func installedModel(for downloadableModel: DownloadableModel) -> InstalledModel? {
        let targetStem = ((downloadableModel.fileName as NSString).deletingPathExtension).lowercased()
        return settingsStore.installedModels.first { installed in
            let stem = ((installed.fileName as NSString).deletingPathExtension).lowercased()
            return stem == targetStem || stem.hasPrefix(targetStem + "-")
        }
    }

    private var availableCatalogModels: [DownloadableModel] {
        models.filter { installedModel(for: $0) == nil }
    }

    private var installedModelsSorted: [InstalledModel] {
        settingsStore.installedModels.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private func installedCapabilities(for installed: InstalledModel) -> ModelCapabilities {
        if let matchedCatalogModel = models.first(where: { catalog in
            installedModel(for: catalog)?.id == installed.id
        }) {
            return matchedCatalogModel.capabilities
        }
        return settingsStore.capabilitiesForFileName(installed.fileName)
    }
}

private struct HubSectionHeader<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DeviceProfileCard: View {
    let deviceProfile: DeviceProfile
    let refreshAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelRow(label: "Model", value: deviceProfile.hardwareIdentifier)
            Divider()
            modelRow(label: "RAM", value: String(format: "%.1f GB", deviceProfile.ramGB))
            Divider()
            modelRow(label: "Free storage", value: String(format: "%.1f GB", deviceProfile.freeStorageGB))

            Button("Refresh device info") {
                refreshAction()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func modelRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground).opacity(0.80))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.24))
            )
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

private struct EmptyStateCard: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground).opacity(0.72))
            )
    }
}

private struct LoadingStateCard: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.72))
        )
    }
}

private struct ErrorStateCard: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.red.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.28))
                    )
            )
    }
}

private struct ModelCard: View {
    let model: DownloadableModel
    let compatibility: ModelCompatibility
    let isDownloadingThisModel: Bool
    let downloadProgress: Double
    let downloadStatusText: String
    let downloadAction: () -> Void
    let cancelDownloadAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)

            Text("\(model.sizeLabel) • \(model.quantization)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(model.repositoryID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("Min RAM: \(String(format: "%.1f", model.minRAMGB)) GB")
                .font(.caption)
                .foregroundStyle(.secondary)

            ModelCapabilitiesRow(capabilities: model.capabilities)

            switch compatibility {
            case .compatible:
                Label("Compatible", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            case let .notCompatible(reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if isDownloadingThisModel {
                DownloadProgressStrip(progress: downloadProgress, status: downloadStatusText)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground).opacity(0.80))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.24))
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

private struct InstalledModelCard: View {
    let model: InstalledModel
    let selectedModelPath: String
    let capabilities: ModelCapabilities
    let useAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.fileName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Text(model.fileSizeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            ModelCapabilitiesRow(capabilities: capabilities)

            HStack(spacing: 8) {
                Button(isSelected ? "Selected" : "Use") {
                    useAction()
                }
                .buttonStyle(.bordered)
                .disabled(isSelected)

                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Text("Delete")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.green.opacity(isSelected ? 0.45 : 0.16), lineWidth: isSelected ? 1.5 : 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        )
    }

    private var isSelected: Bool {
        model.fileURL.path == selectedModelPath
    }
}

private struct DownloadProgressStrip: View {
    let progress: Double
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(Int((max(0, min(progress, 1))) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: max(0, min(progress, 1)))
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.20))
        )
    }
}

private struct ModelCapabilitiesRow: View {
    let capabilities: ModelCapabilities

    var body: some View {
        ViewThatFits(in: .horizontal) {
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

            VStack(alignment: .leading, spacing: 6) {
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
                }
                capabilityTag(
                    title: "Audio",
                    icon: "waveform",
                    supported: capabilities.supportsAudioInput
                )
            }
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
            capabilities: resolvedCapabilities(seed: seed, payload: payload, selectedFileName: selected.rfilename)
        )
    }

    private static func quantizationLabel(from fileName: String) -> String {
        let withoutExtension = (fileName as NSString).deletingPathExtension
        let components = withoutExtension.split(separator: "-")
        guard let last = components.last else { return "GGUF" }
        return String(last)
    }

    private static func resolvedCapabilities(
        seed: ModelSeed,
        payload: HFModelResponse,
        selectedFileName: String
    ) -> ModelCapabilities {
        let tags = payload.tags?.map { $0.lowercased() } ?? []
        let pipeline = payload.pipelineTag?.lowercased() ?? ""
        let fileName = selectedFileName.lowercased()

        var supportsImage = seed.capabilities.supportsImageInput
        if pipeline.contains("image-text-to-text") || pipeline.contains("visual-question-answering") {
            supportsImage = true
        }
        if tags.contains(where: { $0.contains("image-text-to-text") || $0.contains("vision") || $0.contains("multimodal") }) {
            supportsImage = true
        }
        if fileName.contains("gemma-4") || fileName.contains("gemma4") || fileName.contains("vl") {
            supportsImage = true
        }

        var supportsAudio = seed.capabilities.supportsAudioInput
        if pipeline.contains("automatic-speech-recognition") || pipeline.contains("audio") {
            supportsAudio = true
        }
        if tags.contains(where: { $0.contains("audio") || $0.contains("speech") }) {
            supportsAudio = true
        }

        return ModelCapabilities(
            supportsFileInput: true,
            supportsImageInput: supportsImage,
            supportsAudioInput: supportsAudio
        )
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
            capabilities: .nativeVision
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
            capabilities: .nativeVision
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
    let pipelineTag: String?
    let tags: [String]?

    private enum CodingKeys: String, CodingKey {
        case siblings
        case pipelineTag = "pipeline_tag"
        case tags
    }
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
