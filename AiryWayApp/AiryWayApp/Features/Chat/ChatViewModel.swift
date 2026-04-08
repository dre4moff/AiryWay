import Foundation
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published private(set) var conversations: [ChatConversation] = []
    @Published private(set) var selectedConversationID: UUID?
    @Published var isGenerating = false
    @Published var debugItems: [AgentDebugItem] = []
    @Published private(set) var pendingAttachments: [ChatAttachmentPayload] = []

    private weak var settingsStore: SettingsStore?
    private var orchestratorsByConversationID: [UUID: AgentOrchestrator] = [:]
    private var sendTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let conversations = "airyway.chat.conversations.v2"
        static let selectedConversationID = "airyway.chat.selectedConversationID.v2"
    }

    var messages: [ChatMessage] {
        selectedConversation?.messages ?? []
    }

    var conversationList: [ChatConversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func bootstrap(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        loadPersistedConversations()
        ensureConversationExists()
    }

    func createNewConversation() {
        if isGenerating {
            stopGeneration()
        }

        pendingAttachments = []

        let conversation = ChatConversation(
            title: "New chat",
            messages: []
        )
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        persistConversations()
    }

    func selectConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        if isGenerating {
            stopGeneration()
        }
        selectedConversationID = id
        debugItems = []
        pendingAttachments = []
        persistSelectionOnly()
    }

    func deleteConversation(_ id: UUID) {
        guard conversations.count > 1 else { return }
        conversations.removeAll { $0.id == id }
        orchestratorsByConversationID[id] = nil

        if selectedConversationID == id {
            selectedConversationID = conversationList.first?.id
        }

        ensureConversationExists()
        persistConversations()
    }

    func isSelectedConversation(_ id: UUID) -> Bool {
        selectedConversationID == id
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments

        guard (!text.isEmpty || !attachments.isEmpty),
              let settingsStore,
              let conversationID = selectedConversationID,
              let orchestrator = orchestrator(for: conversationID) else {
            return
        }

        sendTask?.cancel()
        inputText = ""
        pendingAttachments = []
        isGenerating = true
        debugItems = []

        let assistantID = UUID()
        appendMessage(ChatMessage(role: .user, text: composeVisibleUserMessage(text: text, attachments: attachments)), to: conversationID)
        let conversationSnapshot = messages(in: conversationID)
        appendMessage(ChatMessage(id: assistantID, role: .assistant, text: ""), to: conversationID)

        sendTask = Task { [weak self] in
            guard let self else { return }

            do {
                let effectiveInput = text
                let result = try await orchestrator.run(
                    userInput: effectiveInput,
                    conversation: conversationSnapshot,
                    attachments: attachments,
                    onFinalToken: { [weak self] token in
                        Task { @MainActor [weak self] in
                            self?.append(token: token, to: assistantID, in: conversationID)
                        }
                    }
                )

                await MainActor.run {
                    self.debugItems = result.debugItems
                    if self.messageText(for: assistantID, in: conversationID).isEmpty {
                        self.replaceMessage(id: assistantID, in: conversationID, with: result.text)
                    }
                    self.updateConversationTitleIfNeeded(id: conversationID)
                    self.isGenerating = false
                    self.sendTask = nil
                    self.persistConversations()
                }
            } catch {
                await MainActor.run {
                    let errorText: String
                    if let llmError = error as? LocalLLMError, case .generationCancelled = llmError {
                        errorText = "Generation stopped."
                    } else if error is CancellationError {
                        errorText = "Generation stopped."
                    } else {
                        errorText = "Error: \(error.localizedDescription)"
                    }

                    self.replaceMessage(id: assistantID, in: conversationID, with: errorText)
                    self.updateConversationTitleIfNeeded(id: conversationID)
                    self.isGenerating = false
                    self.sendTask = nil
                    self.persistConversations()
                }

                settingsStore.stopGeneration()
            }
        }
    }

    func stopGeneration() {
        sendTask?.cancel()
        sendTask = nil
        settingsStore?.stopGeneration()
        isGenerating = false
        persistConversations()
    }

    func removePendingAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearPendingAttachments() {
        pendingAttachments = []
    }

    func addFileAttachment(from url: URL) async {
        do {
            let attachment = try await FileAttachmentExtractor.extract(from: url)
            pendingAttachments.append(attachment)
        } catch {
            settingsStore?.setLastErrorMessage(error.localizedDescription)
        }
    }

    func addImageAttachment(from imageData: Data, preferredName: String = "Image") async {
        guard !imageData.isEmpty else {
            settingsStore?.setLastErrorMessage("Selected image is empty.")
            return
        }

        let sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file)
        let uiImage = UIImage(data: imageData)
        let resolutionLabel: String
        if let uiImage {
            let width = Int(uiImage.size.width.rounded())
            let height = Int(uiImage.size.height.rounded())
            resolutionLabel = "\(width)x\(height)"
        } else {
            resolutionLabel = "unknown resolution"
        }

        let normalizedName: String = {
            let trimmed = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Image" }
            return trimmed
        }()

        let attachment = ChatAttachmentPayload(
            kind: .image,
            name: normalizedName,
            extractedText: "Image attached (\(normalizedName), \(resolutionLabel), \(sizeLabel)).",
            detail: "\(sizeLabel) • \(resolutionLabel)"
        )

        pendingAttachments.append(attachment)
        settingsStore?.setLastErrorMessage(nil)
    }

    func addAudioAttachment(fileURL: URL, duration: TimeInterval) {
        let readableDuration = String(format: "%.1f s", max(0, duration))
        let attachment = ChatAttachmentPayload(
            kind: .audio,
            name: fileURL.lastPathComponent,
            extractedText: "",
            detail: "Recorded audio (\(readableDuration))"
        )
        pendingAttachments.append(attachment)
    }

    private func composeVisibleUserMessage(text: String, attachments: [ChatAttachmentPayload]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentLine: String

        if attachments.isEmpty {
            attachmentLine = ""
        } else {
            let labels = attachments.map { attachment in
                switch attachment.kind {
                case .file: return "[FILE] \(attachment.name)"
                case .image: return "[IMAGE] \(attachment.name)"
                case .audio: return "[AUDIO] \(attachment.name)"
                }
            }
            attachmentLine = "\n\nAttachments: \(labels.joined(separator: ", "))"
        }

        if trimmed.isEmpty {
            return attachmentLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed + attachmentLine
    }

    private var selectedConversation: ChatConversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first(where: { $0.id == selectedConversationID })
    }

    private func messages(in conversationID: UUID) -> [ChatMessage] {
        conversations.first(where: { $0.id == conversationID })?.messages ?? []
    }

    private func appendMessage(_ message: ChatMessage, to conversationID: UUID) {
        mutateConversation(id: conversationID) { conversation in
            conversation.messages.append(message)
            conversation.updatedAt = Date()
        }
    }

    private func append(token: String, to messageID: UUID, in conversationID: UUID) {
        mutateConversation(id: conversationID, persist: false) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].text += token
            conversation.updatedAt = Date()
        }
    }

    private func replaceMessage(id: UUID, in conversationID: UUID, with text: String) {
        mutateConversation(id: conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else {
                conversation.messages.append(ChatMessage(role: .assistant, text: text))
                conversation.updatedAt = Date()
                return
            }
            conversation.messages[index].text = text
            conversation.updatedAt = Date()
        }
    }

    private func messageText(for messageID: UUID, in conversationID: UUID) -> String {
        conversations
            .first(where: { $0.id == conversationID })?
            .messages
            .first(where: { $0.id == messageID })?
            .text ?? ""
    }

    private func updateConversationTitleIfNeeded(id: UUID) {
        mutateConversation(id: id, persist: false) { conversation in
            let normalized = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let canReplace = normalized.isEmpty || normalized == "new chat"
            guard canReplace else { return }

            guard let firstUser = conversation.messages.first(where: { $0.role == .user })?.text
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !firstUser.isEmpty else {
                return
            }

            conversation.title = String(firstUser.prefix(40))
        }
    }

    private func mutateConversation(id: UUID, persist: Bool = true, _ mutate: (inout ChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var updated = conversations[index]
        mutate(&updated)
        conversations[index] = updated

        if persist {
            persistConversations()
        }
    }

    private func ensureConversationExists() {
        if conversations.isEmpty {
            let initial = ChatConversation(
                title: "New chat",
                messages: []
            )
            conversations = [initial]
            selectedConversationID = initial.id
            persistConversations()
            return
        }

        if let selectedConversationID,
           conversations.contains(where: { $0.id == selectedConversationID }) {
            return
        }

        selectedConversationID = conversationList.first?.id
        persistSelectionOnly()
    }

    private func loadPersistedConversations() {
        guard let data = defaults.data(forKey: Keys.conversations),
              let decoded = try? decoder.decode([ChatConversation].self, from: data),
              !decoded.isEmpty else {
            conversations = []
            selectedConversationID = nil
            return
        }

        conversations = decoded.map { conversation in
            var updated = conversation
            updated.messages.removeAll { $0.role == .system }
            return updated
        }
        if let rawSelected = defaults.string(forKey: Keys.selectedConversationID),
           let selected = UUID(uuidString: rawSelected),
           conversations.contains(where: { $0.id == selected }) {
            selectedConversationID = selected
        } else {
            selectedConversationID = conversations.first?.id
        }
    }

    private func persistConversations() {
        if let data = try? encoder.encode(conversations) {
            defaults.set(data, forKey: Keys.conversations)
        }
        persistSelectionOnly()
    }

    private func persistSelectionOnly() {
        defaults.set(selectedConversationID?.uuidString, forKey: Keys.selectedConversationID)
    }

    private func orchestrator(for conversationID: UUID) -> AgentOrchestrator? {
        if let existing = orchestratorsByConversationID[conversationID] {
            return existing
        }
        guard let settingsStore else { return nil }
        let created = AgentOrchestrator(settingsStore: settingsStore)
        orchestratorsByConversationID[conversationID] = created
        return created
    }
}

private enum FileAttachmentExtractor {
    static func extract(from url: URL) async throws -> ChatAttachmentPayload {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let hasScope = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasScope {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    let sizeLabel = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

                    let rawData = try Data(contentsOf: url)
                    let capped = Data(rawData.prefix(1_200_000))

                    let extractedText = decodeText(from: capped)
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let detail = extractedText.isEmpty
                        ? "\(sizeLabel) • no text extraction"
                        : "\(sizeLabel) • text extracted"

                    let attachment = ChatAttachmentPayload(
                        kind: .file,
                        name: url.lastPathComponent,
                        extractedText: String(extractedText.prefix(4_500)),
                        detail: detail
                    )
                    continuation.resume(returning: attachment)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func decodeText(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .unicode) {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        return ""
    }
}
