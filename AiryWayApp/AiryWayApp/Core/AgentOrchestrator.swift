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

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        extractedText: String,
        detail: String
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.extractedText = extractedText
        self.detail = detail
    }
}

@MainActor
final class AgentOrchestrator {
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

        let attachmentText = attachments.map { attachment in
            let cleanedText = attachment.extractedText
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = cleanedText.isEmpty ? "(empty)" : String(cleanedText.prefix(1_500))
            return "[\(attachment.kind.title)] \(attachment.name)\n\(clipped)"
        }
        .joined(separator: "\n\n")

        if userInput.isEmpty {
            return attachmentText
        }

        return "\(userInput)\n\n\(attachmentText)"
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
