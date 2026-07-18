import Foundation
import os.log

private let funASRLogger = Logger(subsystem: "MeetingAI", category: "FunASR")

enum DashScopeTaskStatus: String, Equatable {
    case pending = "PENDING"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case unknown = "UNKNOWN"
    case canceled = "CANCELED"
}

struct DashScopeFunASRSubmitResponse: Equatable {
    let taskID: String
    let status: DashScopeTaskStatus
}

struct DashScopeFunASRSubtaskResult: Equatable {
    let fileURL: String
    let transcriptionURL: URL?
    let subtaskStatus: DashScopeTaskStatus
    let code: String?
    let message: String?
}

struct DashScopeFunASRTaskResponse: Equatable {
    let taskID: String
    let status: DashScopeTaskStatus
    let results: [DashScopeFunASRSubtaskResult]

    var successfulResults: [DashScopeFunASRSubtaskResult] {
        results.filter { $0.subtaskStatus == .succeeded && $0.transcriptionURL != nil }
    }
}

enum DashScopeFunASRError: Error, CustomStringConvertible, LocalizedError {
    case invalidBaseURL
    case invalidResponse(String)
    case apiError(statusCode: Int, body: String)
    case taskFailed(String)
    case timedOut(String)

    var description: String {
        switch self {
        case .invalidBaseURL:
            return "invalid DashScope Fun-ASR base URL"
        case .invalidResponse(let message):
            return "invalid DashScope Fun-ASR response: \(message)"
        case .apiError(let statusCode, let body):
            return "DashScope Fun-ASR API error \(statusCode): \(body)"
        case .taskFailed(let message):
            return "DashScope Fun-ASR task failed: \(message)"
        case .timedOut(let message):
            return "DashScope Fun-ASR task timed out: \(message)"
        }
    }

    var errorDescription: String? {
        description
    }
}

protocol DashScopeHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionDashScopeHTTPTransport: DashScopeHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashScopeFunASRError.invalidResponse("missing HTTPURLResponse")
        }
        return (data, httpResponse)
    }
}

final class DashScopeFunASRProvider: DiarizationTranscriptionProvider {
    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let pollIntervalSeconds: TimeInterval
    private let timeoutSeconds: TimeInterval
    private let transport: DashScopeHTTPTransport

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://dashscope.aliyuncs.com/api/v1")!,
        model: String = "fun-asr",
        pollIntervalSeconds: TimeInterval = 5,
        timeoutSeconds: TimeInterval = 600,
        transport: DashScopeHTTPTransport = URLSessionDashScopeHTTPTransport()
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.pollIntervalSeconds = max(0.5, pollIntervalSeconds)
        self.timeoutSeconds = max(5, timeoutSeconds)
        self.transport = transport
    }

    func submit(_ request: DiarizationTranscriptionRequest) async throws -> DiarizationProviderTask {
        let urlRequest = try Self.makeSubmitURLRequest(
            apiKey: apiKey,
            baseURL: baseURL,
            request: request,
            model: model
        )
        let (data, response) = try await transport.data(for: urlRequest)
        try Self.validate(response: response, data: data)
        let submitResponse = try Self.parseSubmitResponse(data)
        funASRLogger.info("Fun-ASR task submitted: taskID=\(submitResponse.taskID), chunk=\(request.chunk.index), status=\(submitResponse.status.rawValue)")
        return DiarizationProviderTask(
            provider: .dashscopeFunASR,
            taskID: submitResponse.taskID,
            chunkIndex: request.chunk.index,
            state: .submitted,
            remoteFileURL: request.remoteFileURL
        )
    }

    func waitForResult(task: DiarizationProviderTask, chunk: DiarizationAudioChunk) async throws -> DiarizationChunkResult {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) <= timeoutSeconds {
            let request = try Self.makeTaskURLRequest(apiKey: apiKey, baseURL: baseURL, taskID: task.taskID)
            let (data, response) = try await transport.data(for: request)
            try Self.validate(response: response, data: data)
            let taskResponse = try Self.parseTaskResponse(data)

            switch taskResponse.status {
            case .pending, .running:
                try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            case .unknown:
                throw DashScopeFunASRError.taskFailed("task \(task.taskID) returned UNKNOWN status")
            case .failed, .canceled:
                throw DashScopeFunASRError.taskFailed("task \(task.taskID) ended with \(taskResponse.status.rawValue)")
            case .succeeded:
                guard let resultURL = taskResponse.successfulResults.first?.transcriptionURL else {
                    let failures = taskResponse.results.map { "\($0.subtaskStatus.rawValue): \($0.message ?? $0.code ?? "no transcription_url")" }
                        .joined(separator: "; ")
                    throw DashScopeFunASRError.taskFailed(failures.isEmpty ? "no succeeded subtask" : failures)
                }
                let resultRequest = URLRequest(url: resultURL)
                let (resultData, resultResponse) = try await transport.data(for: resultRequest)
                try Self.validate(response: resultResponse, data: resultData)
                return try Self.parseTranscriptionResult(resultData, chunk: chunk)
            }
        }
        throw DashScopeFunASRError.timedOut("task \(task.taskID) exceeded \(Int(timeoutSeconds))s")
    }

    static func makeSubmitURLRequest(
        apiKey: String,
        baseURL: URL,
        request: DiarizationTranscriptionRequest,
        model: String = "fun-asr"
    ) throws -> URLRequest {
        let endpoint = baseURL.appendingPathComponent("services/audio/asr/transcription")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")

        var parameters: [String: Any] = [
            "channel_id": [0],
            "diarization_enabled": request.diarizationEnabled,
            "language_hints": [request.language]
        ]
        if let speakerCount = request.speakerCount, (2...100).contains(speakerCount) {
            parameters["speaker_count"] = speakerCount
        }

        let body: [String: Any] = [
            "model": model,
            "input": ["file_urls": [request.remoteFileURL.absoluteString]],
            "parameters": parameters
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return urlRequest
    }

    static func makeTaskURLRequest(apiKey: String, baseURL: URL, taskID: String) throws -> URLRequest {
        let endpoint = baseURL.appendingPathComponent("tasks/\(taskID)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func parseSubmitResponse(_ data: Data) throws -> DashScopeFunASRSubmitResponse {
        let output = try jsonOutput(from: data)
        guard let taskID = output["task_id"] as? String, !taskID.isEmpty else {
            throw DashScopeFunASRError.invalidResponse("missing output.task_id")
        }
        return DashScopeFunASRSubmitResponse(
            taskID: taskID,
            status: parseStatus(output["task_status"])
        )
    }

    static func parseTaskResponse(_ data: Data) throws -> DashScopeFunASRTaskResponse {
        let output = try jsonOutput(from: data)
        guard let taskID = output["task_id"] as? String, !taskID.isEmpty else {
            throw DashScopeFunASRError.invalidResponse("missing output.task_id")
        }
        let results = (output["results"] as? [[String: Any]] ?? []).map { item in
            DashScopeFunASRSubtaskResult(
                fileURL: item["file_url"] as? String ?? "",
                transcriptionURL: (item["transcription_url"] as? String).flatMap(URL.init(string:)),
                subtaskStatus: parseStatus(item["subtask_status"]),
                code: item["code"] as? String,
                message: item["message"] as? String
            )
        }
        return DashScopeFunASRTaskResponse(
            taskID: taskID,
            status: parseStatus(output["task_status"]),
            results: results
        )
    }

    static func parseTranscriptionResult(_ data: Data, chunk: DiarizationAudioChunk) throws -> DiarizationChunkResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DashScopeFunASRError.invalidResponse("result JSON is not an object")
        }
        let transcripts = json["transcripts"] as? [[String: Any]] ?? []
        let sentences = transcripts.flatMap { transcript -> [ProviderDiarizedSentence] in
            let rawSentences = transcript["sentences"] as? [[String: Any]] ?? []
            return rawSentences.compactMap { sentence in
                guard let begin = sentence["begin_time"] as? Int,
                      let end = sentence["end_time"] as? Int,
                      let text = sentence["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let speakerID = normalizedSpeakerID(from: sentence["speaker_id"])
                return ProviderDiarizedSentence(
                    beginMilliseconds: begin,
                    endMilliseconds: end,
                    speakerID: speakerID,
                    text: text
                )
            }
        }
        return DiarizationChunkResult(chunk: chunk, sentences: sentences)
    }

    private static func jsonOutput(from data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any] else {
            throw DashScopeFunASRError.invalidResponse("missing output object")
        }
        return output
    }

    private static func parseStatus(_ value: Any?) -> DashScopeTaskStatus {
        guard let raw = value as? String else { return .unknown }
        return DashScopeTaskStatus(rawValue: raw.uppercased()) ?? .unknown
    }

    private static func normalizedSpeakerID(from value: Any?) -> String {
        if let value = value as? Int {
            return "speaker-\(value)"
        }
        if let value = value as? String, !value.isEmpty {
            return value.hasPrefix("speaker") ? value : "speaker-\(value)"
        }
        return "speaker-unknown"
    }

    private static func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            throw DashScopeFunASRError.apiError(statusCode: response.statusCode, body: String(body.prefix(500)))
        }
    }
}

enum DiarizationLogSanitizer {
    static func describeRemoteURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? "\(url.scheme ?? "https")://\(url.host ?? "unknown")\(url.path)"
    }

    static func redactSensitiveText(_ value: String) -> String {
        var redacted = value

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(
                in: redacted,
                options: [],
                range: NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            )
            for match in matches.reversed() {
                guard let range = Range(match.range, in: redacted),
                      let url = URL(string: String(redacted[range])),
                      url.query != nil else {
                    continue
                }
                redacted.replaceSubrange(range, with: describeRemoteURL(url))
            }
        }

        redacted = redacted.replacingOccurrences(
            of: #"(?i)Bearer\s+[A-Za-z0-9._~+\-/=]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(x-oss-signature|x-oss-credential|x-oss-security-token|signature|OSSAccessKeyId|AccessKeyId)=([^&\s]+)"#,
            with: "$1=[REDACTED]",
            options: .regularExpression
        )
        return redacted
    }
}
