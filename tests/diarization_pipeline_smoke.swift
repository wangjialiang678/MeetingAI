import Foundation

enum DiarizationPipelineSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private final class FakePipelineUploader: DiarizationAudioUploader {
    var uploadedChunks: [Int] = []

    func upload(_ request: DiarizationUploadRequest) async throws -> DiarizationUploadResult {
        uploadedChunks.append(request.chunk.index)
        return DiarizationUploadResult(
            remoteFileURL: URL(string: "https://bucket.oss-cn-beijing.aliyuncs.com/meetingai/chunk-\(request.chunk.index).wav?x-oss-signature=secret")!,
            storageProvider: .oss,
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
    }
}

private final class FakePipelineProvider: DiarizationTranscriptionProvider {
    var submittedChunks: [Int] = []

    func submit(_ request: DiarizationTranscriptionRequest) async throws -> DiarizationProviderTask {
        submittedChunks.append(request.chunk.index)
        return DiarizationProviderTask(
            provider: .dashscopeFunASR,
            taskID: "task-\(request.chunk.index)",
            chunkIndex: request.chunk.index,
            state: .submitted,
            remoteFileURL: request.remoteFileURL
        )
    }

    func waitForResult(task: DiarizationProviderTask, chunk: DiarizationAudioChunk) async throws -> DiarizationChunkResult {
        DiarizationChunkResult(
            chunk: DiarizationAudioChunk(
                index: chunk.index,
                startMilliseconds: chunk.startMilliseconds,
                endMilliseconds: chunk.endMilliseconds,
                localURL: chunk.localURL,
                state: .completed,
                taskID: task.taskID
            ),
            sentences: [
                ProviderDiarizedSentence(
                    beginMilliseconds: 100,
                    endMilliseconds: 900,
                    speakerID: "speaker-0",
                    text: "第一位发言"
                )
            ]
        )
    }
}

private final class FailingPipelineProvider: DiarizationTranscriptionProvider {
    func submit(_ request: DiarizationTranscriptionRequest) async throws -> DiarizationProviderTask {
        throw NSError(
            domain: "FakeProvider",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "failed URL https://bucket.oss-cn-beijing.aliyuncs.com/chunk.wav?x-oss-signature=secret Authorization: Bearer sk-test"
            ]
        )
    }

    func waitForResult(task: DiarizationProviderTask, chunk: DiarizationAudioChunk) async throws -> DiarizationChunkResult {
        throw NSError(domain: "FakeProvider", code: 2)
    }
}

@main
struct DiarizationPipelineSmoke {
    static func main() async {
        do {
            try await testPipelineUploadsSubmitsBackfillsAndRedacts()
            try await testPipelineFailureRedactsSensitiveErrorText()
            print("Diarization pipeline smoke tests PASS")
        } catch {
            fputs("Diarization pipeline smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw DiarizationPipelineSmokeFailure.failed(message)
        }
    }

    private static func makeSessionURL() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetingai-diarization-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("2026-05-23-20-00-00.txt")
    }

    private static func testPipelineUploadsSubmitsBackfillsAndRedacts() async throws {
        let sessionURL = try makeSessionURL()
        let eventLogURL = sessionURL.deletingPathExtension().appendingPathExtension("events.log")
        let uploader = FakePipelineUploader()
        let provider = FakePipelineProvider()
        var updatedSegments: [DiarizedTranscriptSegment] = []
        let pipeline = DiarizationPipeline(
            sessionFileURL: sessionURL,
            eventLogURL: eventLogURL,
            language: "zh",
            uploader: uploader,
            provider: provider,
            speakerCount: 2,
            onSegmentsUpdated: { segments in
                updatedSegments = segments
            }
        )

        let chunk = DiarizationAudioChunk(
            index: 0,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-0.wav"),
            state: .waitingForUpload
        )

        try await pipeline.process(chunk)

        try expect(uploader.uploadedChunks == [0], "pipeline should upload chunk")
        try expect(provider.submittedChunks == [0], "pipeline should submit provider task")
        try expect(updatedSegments.count == 1, "pipeline should publish merged speaker segment")
        try expect(updatedSegments[0].speakerID == "speaker-0", "pipeline should preserve speaker id")

        let diarizedURL = sessionURL.deletingPathExtension().appendingPathExtension("diarized.jsonl")
        let transcriptURL = sessionURL.deletingPathExtension().appendingPathExtension("transcript.md")
        let eventLog = try String(contentsOf: eventLogURL, encoding: .utf8)
        let jsonl = try String(contentsOf: diarizedURL, encoding: .utf8)
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)

        try expect(jsonl.contains("\"speakerID\":\"speaker-0\""), "pipeline should persist diarized jsonl")
        try expect(transcript.contains("## 说话人分离回填"), "pipeline should append speaker markdown")
        try expect(eventLog.contains("\"event\":\"diarization_upload_started\""), "pipeline should log upload start")
        try expect(eventLog.contains("\"event\":\"diarization_upload_completed\""), "pipeline should log upload completion")
        try expect(eventLog.contains("\"event\":\"diarization_task_submitted\""), "pipeline should log task submission")
        try expect(eventLog.contains("\"event\":\"diarization_task_completed\""), "pipeline should log task completion")
        try expect(!eventLog.contains("x-oss-signature"), "pipeline event log should not contain signed URL query")
        try expect(!eventLog.contains("secret"), "pipeline event log should not contain signature value")
    }

    private static func testPipelineFailureRedactsSensitiveErrorText() async throws {
        let sessionURL = try makeSessionURL()
        let eventLogURL = sessionURL.deletingPathExtension().appendingPathExtension("events.log")
        let pipeline = DiarizationPipeline(
            sessionFileURL: sessionURL,
            eventLogURL: eventLogURL,
            language: "zh",
            uploader: FakePipelineUploader(),
            provider: FailingPipelineProvider()
        )
        let chunk = DiarizationAudioChunk(
            index: 1,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-1.wav"),
            state: .waitingForUpload
        )

        do {
            _ = try await pipeline.process(chunk)
            try expect(false, "pipeline should throw provider error")
        } catch {
            let eventLog = try String(contentsOf: eventLogURL, encoding: .utf8)
            try expect(eventLog.contains("\"event\":\"diarization_task_failed\""), "pipeline should log failed task")
            try expect(!eventLog.contains("x-oss-signature"), "failure log should redact signed URL query key")
            try expect(!eventLog.contains("secret"), "failure log should redact signed URL query value")
            try expect(!eventLog.contains("Bearer sk-test"), "failure log should redact bearer token")
        }
    }
}
