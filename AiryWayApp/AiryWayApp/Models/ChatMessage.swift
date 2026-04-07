import Foundation

struct ChatMessage: Identifiable, Hashable, Codable {
    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }
}
