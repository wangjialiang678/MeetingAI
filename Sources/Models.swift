import Foundation

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let isFinal: Bool
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let timestamp: Date
    let role: MessageRole
    let content: String

    enum MessageRole {
        case system
        case user
        case assistant
    }
}
