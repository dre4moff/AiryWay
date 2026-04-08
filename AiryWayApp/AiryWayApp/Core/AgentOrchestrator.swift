import Foundation

struct AgentDebugItem: Identifiable, Hashable {
    let id = UUID()
    let stage: String
    let detail: String
    let durationMS: Int
    let timestamp: Date
}

struct AgentRunResult {
    let text: String
    let debugItems: [AgentDebugItem]
}

struct ChatAttachmentPayload: Identifiable, Hashable {
    enum Kind: String {
        case file
        case image
        case audio

        var title: String {
            switch self {
            case .file: return "File"
            case .image: return "Immagine"
            case .audio: return "Audio"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let name: String
    let extractedText: String
    let detail: String
    let binaryPayload: Data?

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        extractedText: String,
        detail: String,
        binaryPayload: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.extractedText = extractedText
        self.detail = detail
        self.binaryPayload = binaryPayload
    }

    static func == (lhs: ChatAttachmentPayload, rhs: ChatAttachmentPayload) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
final class AgentOrchestrator {
    private static let mediaMarker = "<__media__>"
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func run(
        userInput: String,
        conversation: [ChatMessage] = [],
        attachments: [ChatAttachmentPayload] = [],
        onFinalToken: @escaping @Sendable (String) -> Void
    ) async throws -> AgentRunResult {
        if attachments.contains(where: { $0.kind == .image }),
           !settingsStore.isNativeImageInputRuntimeAvailable {
            throw LocalLLMError.backend(
                "Image input is not available in this runtime build. Update llama.xcframework with native multimodal support."
            )
        }

        let request = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let preparedPrompt = buildPrompt(userInput: request, attachments: attachments)
        let modelConversation = buildConversation(
            from: conversation,
            preparedPrompt: preparedPrompt
        )

        let startedAt = Date()
        let response = try await settingsStore.generate(
            prompt: preparedPrompt,
            context: "",
            conversation: modelConversation,
            attachments: attachments,
            onToken: onFinalToken
        )
        let outputText = response.text

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let summary = "prompt chars: \(preparedPrompt.count), output chars: \(outputText.count), attachments: \(attachments.count), turns: \(modelConversation.count)"

        return AgentRunResult(
            text: outputText,
            debugItems: [
                AgentDebugItem(
                    stage: "offline.generate",
                    detail: summary,
                    durationMS: elapsed,
                    timestamp: Date()
                )
            ]
        )
    }

    private func buildPrompt(
        userInput: String,
        attachments: [ChatAttachmentPayload]
    ) -> String {
        guard !attachments.isEmpty else {
            return userInput
        }

        let input = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaAttachments = attachments.filter { $0.kind == .image }
        let textAttachments = attachments.filter { $0.kind != .image }

        let attachmentText = textAttachments.map { attachment in
            let cleanedText = attachment.extractedText
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = cleanedText.isEmpty ? "(empty)" : String(cleanedText.prefix(1_500))
            return "[\(attachment.kind.title)] \(attachment.name)\n\(clipped)"
        }
        .joined(separator: "\n\n")

        let mediaMarkers = mediaAttachments
            .map { _ in Self.mediaMarker }
            .joined(separator: "\n")

        var sections: [String] = []
        if !input.isEmpty {
            sections.append(input)
        }
        if !attachmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(attachmentText)
        }
        if !mediaMarkers.isEmpty {
            sections.append(mediaMarkers)
        }

        if sections.isEmpty {
            return input
        }

        return sections.joined(separator: "\n\n")
    }

    private func buildConversation(
        from conversation: [ChatMessage],
        preparedPrompt: String
    ) -> [ChatMessage] {
        var result: [ChatMessage] = conversation.compactMap { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChatMessage(id: message.id, role: message.role, text: text)
        }

        guard !preparedPrompt.isEmpty else { return result }

        if let last = result.indices.last, result[last].role == .user {
            result[last].text = preparedPrompt
        } else {
            result.append(ChatMessage(role: .user, text: preparedPrompt))
        }

        return result
    }

    // Pass-through orchestration: no app-side retries/dedup/behavior forcing.
}
