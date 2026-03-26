import Foundation

/// A single classified chat message from the Dia conversation.
struct ChatMessage {
    enum Role: String {
        case user
        case assistant
        case tool
    }

    let role: Role
    let text: String
}
