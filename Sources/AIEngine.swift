import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "AIEngine")

class AIEngine {
    private let apiKey: String
    private let model: String
    private let baseURL: String

    init(apiKey: String, model: String = "MiniMax-M2.5", baseURL: String = "https://api.minimaxi.com/v1/text/chatcompletion_v2") {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    func analyze(systemPrompt: String, userContent: String) async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw AIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.7,
            "max_tokens": 4096
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("Sending AI request: model=\(self.model), content length=\(userContent.count)")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        logger.info("AI response: status=\(httpResponse.statusCode)")
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            logger.error("AI API error: \(httpResponse.statusCode) - \(errorBody.prefix(200))")
            throw AIError.apiError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.parseError
        }

        return content
    }

    enum AIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case apiError(statusCode: Int, body: String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid API URL"
            case .invalidResponse: return "Invalid response"
            case .apiError(let code, let body): return "API error (\(code)): \(body)"
            case .parseError: return "Failed to parse response"
            }
        }
    }
}
