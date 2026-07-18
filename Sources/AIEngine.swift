import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "AIEngine")

struct StructuredAnalysis {
    let shouldSpeak: Bool
    let content: String
    let kind: InsightCard.Kind
    let topicKeywords: [String]
    let execution: AnalysisExecutionMetadata
}

class AIEngine {
    private let apiKey: String
    private let model: String
    private let baseURL: String
    private let fixtureMode: Bool
    private let backend: AnalysisBackendMode
    private let codexModel: String

    init(
        apiKey: String,
        model: String = "qwen/qwen3.5-122b-a10b",
        baseURL: String = "https://integrate.api.nvidia.com/v1/chat/completions",
        fixtureMode: Bool = false,
        backend: AnalysisBackendMode = .http,
        codexModel: String = "gpt-5.4"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.fixtureMode = fixtureMode
        self.backend = backend
        self.codexModel = codexModel
    }

    func analyze(systemPrompt: String, userContent: String, intent: AnalysisIntent = .reply) async throws -> TextAnalysisResult {
        if fixtureMode {
            logger.info("Returning fixture AI reply")
            return TextAnalysisResult(
                content: "测试回复：建议先确认当前讨论的关键假设，再决定下一步行动。",
                execution: AnalysisExecutionMetadata(
                    configuredBackend: backend,
                    usedBackend: backend.preferredBackend(for: intent),
                    fallbackOccurred: false,
                    durationSeconds: 0.0
                )
            )
        }

        let selectedBackend = resolveBackend(intent: intent, systemPrompt: systemPrompt)
        logger.info("Analyze request routed: intent=\(intent.rawValue), configured=\(self.backend.rawValue), selected=\(selectedBackend.rawValue), chars=\(userContent.count)")
        if selectedBackend == .codexCLI {
            let startedAt = Date()
            do {
                let content = try await analyzeViaCodexCLI(systemPrompt: systemPrompt, userContent: userContent)
                let duration = Date().timeIntervalSince(startedAt)
                logger.info("Codex CLI analyze succeeded in \(String(format: "%.2f", duration))s")
                return TextAnalysisResult(
                    content: content,
                    execution: AnalysisExecutionMetadata(
                        configuredBackend: backend,
                        usedBackend: .codexCLI,
                        fallbackOccurred: false,
                        durationSeconds: duration
                    )
                )
            } catch {
                logger.error("Codex CLI analyze failed, falling back to HTTP: \(error.localizedDescription)")
                let httpStartedAt = Date()
                let content = try await analyzeViaHTTP(systemPrompt: systemPrompt, userContent: userContent)
                let duration = Date().timeIntervalSince(httpStartedAt)
                logger.info("HTTP fallback analyze succeeded in \(String(format: "%.2f", duration))s")
                return TextAnalysisResult(
                    content: content,
                    execution: AnalysisExecutionMetadata(
                        configuredBackend: backend,
                        usedBackend: .http,
                        fallbackOccurred: true,
                        durationSeconds: duration
                    )
                )
            }
        }

        let startedAt = Date()
        let content = try await analyzeViaHTTP(systemPrompt: systemPrompt, userContent: userContent)
        let duration = Date().timeIntervalSince(startedAt)
        logger.info("HTTP analyze succeeded in \(String(format: "%.2f", duration))s")
        return TextAnalysisResult(
            content: content,
            execution: AnalysisExecutionMetadata(
                configuredBackend: backend,
                usedBackend: .http,
                fallbackOccurred: false,
                durationSeconds: duration
            )
        )
    }

    private func analyzeViaHTTP(systemPrompt: String, userContent: String) async throws -> String {
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

        do {
            return try Self.extractChatMessageText(from: data)
        } catch {
            let rawBody = String(data: data, encoding: .utf8) ?? "(binary)"
            logger.error("Failed to parse AI response: \(rawBody.prefix(500))")
            throw error
        }
    }

    static func extractChatMessageText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIError.parseError
        }

        if let content = message["content"] as? String,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }

        if let contentParts = message["content"] as? [[String: Any]] {
            let text = contentParts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }
            .joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        if let reasoningContent = message["reasoning_content"] as? String,
           !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reasoningContent
        }

        throw AIError.parseError
    }

    func analyzeStructured(
        systemPrompt: String,
        userContent: String,
        intent: AnalysisIntent = .insight
    ) async throws -> StructuredAnalysis {
        if fixtureMode {
            logger.info("Returning fixture structured analysis")
            let isSummary = systemPrompt.contains("这一轮请做一次「阶段小结」")
                || systemPrompt.contains("请对刚才的讨论阶段做一个简短的小结")
            let usedBackend = backend.preferredBackend(for: intent)
            return StructuredAnalysis(
                shouldSpeak: true,
                content: isSummary
                    ? "测试小结：讨论聚焦在企业家私董会的提问质量，下一步应先明确主持规则和记录方式。"
                    : "测试洞察：最近几分钟的讨论集中在主持流程与提问质量，建议先明确一轮问题收集标准。",
                kind: isSummary ? .summary : .insight,
                topicKeywords: ["测试", "私董会", "提问", "流程"],
                execution: AnalysisExecutionMetadata(
                    configuredBackend: backend,
                    usedBackend: usedBackend,
                    fallbackOccurred: false,
                    durationSeconds: 0.0
                )
            )
        }

        let selectedBackend = resolveBackend(intent: intent, systemPrompt: systemPrompt)
        logger.info("Structured analyze routed: intent=\(intent.rawValue), configured=\(self.backend.rawValue), selected=\(selectedBackend.rawValue), chars=\(userContent.count)")
        let rawText: String
        let execution: AnalysisExecutionMetadata
        if selectedBackend == .codexCLI {
            let startedAt = Date()
            do {
                rawText = try await analyzeViaCodexCLIStructured(systemPrompt: systemPrompt, userContent: userContent)
                let duration = Date().timeIntervalSince(startedAt)
                logger.info("Codex CLI structured analyze succeeded in \(String(format: "%.2f", duration))s")
                execution = AnalysisExecutionMetadata(
                    configuredBackend: backend,
                    usedBackend: .codexCLI,
                    fallbackOccurred: false,
                    durationSeconds: duration
                )
            } catch {
                logger.error("Codex CLI structured analyze failed, falling back to HTTP: \(error.localizedDescription)")
                let httpStartedAt = Date()
                rawText = try await analyzeViaHTTP(systemPrompt: systemPrompt, userContent: userContent)
                let duration = Date().timeIntervalSince(httpStartedAt)
                logger.info("HTTP fallback structured analyze succeeded in \(String(format: "%.2f", duration))s")
                execution = AnalysisExecutionMetadata(
                    configuredBackend: backend,
                    usedBackend: .http,
                    fallbackOccurred: true,
                    durationSeconds: duration
                )
            }
        } else {
            let startedAt = Date()
            rawText = try await analyzeViaHTTP(systemPrompt: systemPrompt, userContent: userContent)
            let duration = Date().timeIntervalSince(startedAt)
            logger.info("HTTP structured analyze succeeded in \(String(format: "%.2f", duration))s")
            execution = AnalysisExecutionMetadata(
                configuredBackend: backend,
                usedBackend: .http,
                fallbackOccurred: false,
                durationSeconds: duration
            )
        }

        guard let data = rawText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shouldSpeak = json["should_speak"] as? Bool,
              let content = json["content"] as? String else {
            logger.warning("AI returned non-JSON, falling back to raw text (\(rawText.count) chars): \(rawText.prefix(100))")
            return StructuredAnalysis(
                shouldSpeak: true,
                content: rawText,
                kind: .insight,
                topicKeywords: [],
                execution: execution
            )
        }

        let rawKind = (json["kind"] as? String) ?? "insight"
        let kind = InsightCard.Kind(rawValue: rawKind) ?? .insight
        let topicKeywords = (json["topic_keywords"] as? [String]) ?? []

        return StructuredAnalysis(
            shouldSpeak: shouldSpeak,
            content: content,
            kind: kind,
            topicKeywords: topicKeywords,
            execution: execution
        )
    }

    private func resolveBackend(intent: AnalysisIntent, systemPrompt: String) -> AnalysisBackendMode {
        switch backend {
        case .http, .codexCLI:
            return backend
        case .hybrid:
            if systemPrompt.contains("这一轮请做一次「阶段小结」")
                || systemPrompt.contains("请对刚才的讨论阶段做一个简短的小结")
                || intent == .summary
                || intent == .reply {
                return .http
            }
            return .codexCLI
        }
    }

    private func analyzeViaCodexCLI(systemPrompt: String, userContent: String) async throws -> String {
        let schema = """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["content"],
          "properties": {
            "content": { "type": "string" }
          }
        }
        """
        let prompt = """
        你是会议中的 AI 助手。不要运行任何工具，不要读写任何文件，只直接回答。

        system prompt:
        \(systemPrompt)

        user content:
        \(userContent)
        """
        let raw = try runCodexExec(prompt: prompt, schemaJSON: schema)
        guard let data = raw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String else {
            throw AIError.parseError
        }
        return content
    }

    private func analyzeViaCodexCLIStructured(systemPrompt: String, userContent: String) async throws -> String {
        let schema = """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["should_speak", "content", "kind", "topic_keywords"],
          "properties": {
            "should_speak": { "type": "boolean" },
            "content": { "type": "string" },
            "kind": { "type": "string", "enum": ["insight", "reply", "summary"] },
            "topic_keywords": { "type": "array", "items": { "type": "string" } }
          }
        }
        """
        let prompt = """
        你是会议中的 AI 助手。不要运行任何工具，不要读写任何文件，只直接思考并输出结果。

        system prompt:
        \(systemPrompt)

        user content:
        \(userContent)
        """
        return try runCodexExec(prompt: prompt, schemaJSON: schema)
    }

    private func runCodexExec(prompt: String, schemaJSON: String) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let schemaURL = tmpDir.appendingPathComponent("schema.json")
        let outputURL = tmpDir.appendingPathComponent("output.json")
        try schemaJSON.write(to: schemaURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "codex",
            "-s", "read-only",
            "exec",
            "-m", codexModel,
            "--skip-git-repo-check",
            "--output-schema", schemaURL.path,
            "-o", outputURL.path,
            "-"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        logger.info("Launching Codex CLI: model=\(self.codexModel), cwd=\(process.currentDirectoryURL?.path ?? "-"), promptChars=\(prompt.count)")

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if let promptData = prompt.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(promptData)
        }
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.error("Codex CLI terminated abnormally: code=\(process.terminationStatus), stderr=\(stderr.prefix(300)), stdout=\(stdout.prefix(200))")
            throw AIError.codexCLIError(stderr: stderr, stdout: stdout)
        }

        return try String(contentsOf: outputURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum AIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case apiError(statusCode: Int, body: String)
        case parseError
        case codexCLIError(stderr: String, stdout: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "模型服务地址无效，请检查配置。"
            case .invalidResponse:
                return "模型服务返回了无效响应。"
            case .apiError(let code, _):
                return "模型服务返回错误（HTTP \(code)）。"
            case .parseError:
                return "模型响应解析失败。"
            case .codexCLIError:
                return "Codex CLI 调用失败，请检查登录状态或本机 CLI 环境"
            }
        }
    }
}
