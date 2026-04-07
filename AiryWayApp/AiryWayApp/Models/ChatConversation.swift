import Foundation

struct ChatConversation: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var previewText: String {
        let last = messages.last(where: { $0.role != .system })?.text ?? ""
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
