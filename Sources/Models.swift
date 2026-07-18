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
    var execution: AnalysisExecutionMetadata?

    enum Kind: String, Codable {
        case insight
        case reply
        case summary
        case system
    }

    init(
        content: String,
        kind: Kind = .insight,
        userQuery: String? = nil,
        execution: AnalysisExecutionMetadata? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.content = content
        self.kind = kind
        self.isPinned = false
        self.userQuery = userQuery
        self.execution = execution
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

enum AnalysisBackendMode: String, CaseIterable, Codable {
    case http = "http"
    case codexCLI = "codex_cli"
    case hybrid = "hybrid"

    var displayName: String {
        switch self {
        case .http: return "HTTP"
        case .codexCLI: return "Codex CLI"
        case .hybrid: return "Hybrid"
        }
    }

    var description: String {
        switch self {
        case .http:
            return "全部走当前 HTTP 模型，适合低延迟总结和常规分析。"
        case .codexCLI:
            return "全部走本机 Codex CLI，适合深度推理，但延时更高。"
        case .hybrid:
            return "洞察优先走 Codex CLI，总结和问答走 HTTP。"
        }
    }

    func preferredBackend(for intent: AnalysisIntent) -> AnalysisBackendMode {
        switch self {
        case .http, .codexCLI:
            return self
        case .hybrid:
            switch intent {
            case .insight:
                return .codexCLI
            case .summary, .reply:
                return .http
            }
        }
    }
}

enum AnalysisIntent: String {
    case insight
    case summary
    case reply
}

struct AnalysisExecutionMetadata {
    let configuredBackend: AnalysisBackendMode
    let usedBackend: AnalysisBackendMode
    let fallbackOccurred: Bool
    let durationSeconds: Double

    var backendBadgeText: String {
        if fallbackOccurred {
            return "\(usedBackend.displayName) 回退"
        }
        return usedBackend.displayName
    }

    var statusText: String {
        let duration = String(format: "%.1fs", durationSeconds)
        let routeText: String
        if configuredBackend == usedBackend {
            routeText = usedBackend.displayName
        } else {
            routeText = "\(configuredBackend.displayName) → \(usedBackend.displayName)"
        }
        if fallbackOccurred {
            return "最近一次：Codex CLI 失败，已回退到 \(usedBackend.displayName) · \(duration)"
        }
        return "最近一次：\(routeText) · \(duration)"
    }
}

struct TextAnalysisResult {
    let content: String
    let execution: AnalysisExecutionMetadata
}
