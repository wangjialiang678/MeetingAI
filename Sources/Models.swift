import Foundation

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let isFinal: Bool
}

struct InsightCard: Identifiable {
    let id: UUID
    let timestamp: Date
    var content: String
    var kind: Kind
    var isPinned: Bool
    var userQuery: String?

    enum Kind: String, Codable {
        case insight
        case reply
        case summary
    }

    init(content: String, kind: Kind = .insight, userQuery: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.content = content
        self.kind = kind
        self.isPinned = false
        self.userQuery = userQuery
    }
}

enum AIMode: String, CaseIterable {
    case observer = "observer"
    case advisor = "advisor"
    case researcher = "researcher"

    var displayName: String {
        switch self {
        case .observer: return "观察者"
        case .advisor: return "顾问"
        case .researcher: return "研究员"
        }
    }
}
