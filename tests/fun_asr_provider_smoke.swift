import Foundation

enum FunASRProviderSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private final class SequenceFunASRTransport: DashScopeHTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private(set) var requestCount = 0

    init(responses: [(Data, HTTPURLResponse)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        guard !responses.isEmpty else {
            throw FunASRProviderSmokeFailure.failed("transport received unexpected request")
        }
        return responses.removeFirst()
    }
}

@main
struct FunASRProviderSmoke {
    static func main() async {
        do {
            try testSubmitRequestAndResponseParsing()
            try testTaskPollingResponseRequiresSubtaskSuccess()
            try testTranscriptionResultParsing()
            try testRemoteURLDescriptionDropsQuerySecrets()
            try testRedactionCoversOSSv4QueryFragments()
            try await testUnknownTaskStatusFailsFast()
            print("Fun-ASR provider smoke tests PASS")
        } catch {
            fputs("Fun-ASR provider smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw FunASRProviderSmokeFailure.failed(message)
        }
    }

    private static func testSubmitRequestAndResponseParsing() throws {
        let chunk = DiarizationAudioChunk(
            index: 1,
            startMilliseconds: 30_000,
            endMilliseconds: 60_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-1.wav"),
            state: .waitingForUpload
        )
        let transcriptionRequest = DiarizationTranscriptionRequest(
            chunk: chunk,
            remoteFileURL: URL(string: "https://example.com/meeting/chunk-1.wav?Signature=secret")!,
            language: "zh",
            diarizationEnabled: true,
            speakerCount: 2
        )

        let request = try DashScopeFunASRProvider.makeSubmitURLRequest(
            apiKey: "fake-api-key",
            baseURL: URL(string: "https://dashscope.aliyuncs.com/api/v1")!,
            request: transcriptionRequest
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let input = body?["input"] as? [String: Any]
        let parameters = body?["parameters"] as? [String: Any]

        try expect(request.httpMethod == "POST", "submit request should use POST")
        try expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription", "submit URL should target transcription endpoint")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-api-key", "submit request should set bearer auth")
        try expect(request.value(forHTTPHeaderField: "X-DashScope-Async") == "enable", "submit request should enable async mode")
        try expect((body?["model"] as? String) == "fun-asr", "submit request should use fun-asr")
        try expect((input?["file_urls"] as? [String])?.first == transcriptionRequest.remoteFileURL.absoluteString, "submit request should include remote file URL")
        try expect((parameters?["diarization_enabled"] as? Bool) == true, "submit request should enable diarization")
        try expect((parameters?["speaker_count"] as? Int) == 2, "submit request should pass optional speaker count")
        try expect((parameters?["language_hints"] as? [String]) == ["zh"], "submit request should pass language hint")

        let data = """
        {"request_id":"req-1","output":{"task_status":"PENDING","task_id":"task-1"}}
        """.data(using: .utf8)!
        let response = try DashScopeFunASRProvider.parseSubmitResponse(data)
        try expect(response.taskID == "task-1", "submit parser should extract task id")
        try expect(response.status == .pending, "submit parser should extract pending status")
    }

    private static func testTaskPollingResponseRequiresSubtaskSuccess() throws {
        let data = """
        {
          "request_id": "req-2",
          "output": {
            "task_id": "task-2",
            "task_status": "SUCCEEDED",
            "results": [
              {
                "file_url": "https://example.com/chunk-2.wav",
                "transcription_url": "https://dashscope-result.example/result.json?Expires=1&Signature=secret",
                "subtask_status": "SUCCEEDED"
              },
              {
                "file_url": "https://example.com/chunk-3.wav",
                "code": "InvalidFile.DownloadFailed",
                "message": "download failed",
                "subtask_status": "FAILED"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let response = try DashScopeFunASRProvider.parseTaskResponse(data)
        try expect(response.taskID == "task-2", "task parser should preserve task id")
        try expect(response.status == .succeeded, "task parser should parse succeeded status")
        try expect(response.results.count == 2, "task parser should preserve all subtasks")
        try expect(response.successfulResults.count == 1, "task parser should expose only succeeded subtasks")
        try expect(response.successfulResults[0].transcriptionURL?.host == "dashscope-result.example", "task parser should parse transcription URL")
        try expect(response.results[1].subtaskStatus == .failed, "task parser should keep failed subtask status")
    }

    private static func testTranscriptionResultParsing() throws {
        let chunk = DiarizationAudioChunk(
            index: 2,
            startMilliseconds: 60_000,
            endMilliseconds: 90_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-2.wav"),
            state: .submitted,
            taskID: "task-2"
        )
        let data = """
        {
          "file_url": "https://example.com/meeting/chunk-2.wav",
          "properties": {
            "audio_format": "pcm_s16le",
            "channels": [0],
            "original_sampling_rate": 16000,
            "original_duration_in_milliseconds": 30000
          },
          "transcripts": [
            {
              "channel_id": 0,
              "content_duration_in_milliseconds": 28000,
              "text": "大家好，我们开始。下一位回应。",
              "sentences": [
                {"begin_time": 100, "end_time": 1600, "text": "大家好，我们开始。", "speaker_id": 0},
                {"begin_time": 1800, "end_time": 3400, "text": "下一位回应。", "speaker_id": 1}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try DashScopeFunASRProvider.parseTranscriptionResult(data, chunk: chunk)
        try expect(result.chunk.index == 2, "transcription parser should preserve chunk")
        try expect(result.sentences.count == 2, "transcription parser should extract sentence rows")
        try expect(result.sentences[0].speakerID == "speaker-0", "transcription parser should normalize first speaker")
        try expect(result.sentences[1].speakerID == "speaker-1", "transcription parser should normalize second speaker")
        try expect(result.sentences[0].beginMilliseconds == 100, "transcription parser should preserve begin time")
        try expect(result.sentences[1].text == "下一位回应。", "transcription parser should preserve text")
    }

    private static func testRemoteURLDescriptionDropsQuerySecrets() throws {
        let url = URL(string: "https://bucket.oss-cn-beijing.aliyuncs.com/meetingai/chunk.wav?x-oss-signature=secret&OSSAccessKeyId=ak")!
        let safe = DiarizationLogSanitizer.describeRemoteURL(url)
        try expect(safe == "https://bucket.oss-cn-beijing.aliyuncs.com/meetingai/chunk.wav", "remote URL log description should drop query string")
        try expect(!safe.contains("secret"), "remote URL log description should not include signature")
        try expect(!safe.contains("OSSAccessKeyId"), "remote URL log description should not include access key query")
    }

    private static func testRedactionCoversOSSv4QueryFragments() throws {
        let unsafe = "upload failed x-oss-credential=ak/20260523/cn/oss/aliyun_v4_request&x-oss-security-token=sts-token&x-oss-signature=sig"
        let safe = DiarizationLogSanitizer.redactSensitiveText(unsafe)
        try expect(!safe.contains("ak/20260523"), "redaction should remove x-oss-credential value")
        try expect(!safe.contains("sts-token"), "redaction should remove x-oss-security-token value")
        try expect(!safe.contains("=sig"), "redaction should remove x-oss-signature value")
    }

    private static func testUnknownTaskStatusFailsFast() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/task-unknown")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = """
        {"request_id":"req","output":{"task_id":"task-unknown","task_status":"UNKNOWN"}}
        """.data(using: .utf8)!
        let transport = SequenceFunASRTransport(responses: [(data, response)])
        let provider = DashScopeFunASRProvider(
            apiKey: "fake",
            baseURL: URL(string: "https://dashscope.aliyuncs.com/api/v1")!,
            pollIntervalSeconds: 0.5,
            timeoutSeconds: 5,
            transport: transport
        )
        let chunk = DiarizationAudioChunk(
            index: 9,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-9.wav"),
            state: .submitted,
            taskID: "task-unknown"
        )
        let task = DiarizationProviderTask(
            provider: .dashscopeFunASR,
            taskID: "task-unknown",
            chunkIndex: 9,
            state: .submitted,
            remoteFileURL: URL(string: "https://example.com/chunk.wav")!
        )

        do {
            _ = try await provider.waitForResult(task: task, chunk: chunk)
            try expect(false, "UNKNOWN task status should fail fast")
        } catch let error as DashScopeFunASRError {
            try expect(String(describing: error).contains("UNKNOWN"), "UNKNOWN failure should include provider status")
            try expect(transport.requestCount == 1, "UNKNOWN should not keep polling until timeout")
        }
    }
}
