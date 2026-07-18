import Foundation

enum DiarizationBackfillSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct DiarizationBackfillSmoke {
    static func main() {
        do {
            try testDiarizedJSONLAndSpeakerMarkdownBackfill()
            try testProviderResultMergeThenBackfill()
            try testBackfillLifecycleEvent()
            print("Diarization backfill smoke tests PASS")
        } catch {
            fputs("Diarization backfill smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw DiarizationBackfillSmokeFailure.failed(message)
        }
    }

    private static func makeSessionURL() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetingai-diarization-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("2026-05-23-19-00-00.txt")
    }

    private static func testDiarizedJSONLAndSpeakerMarkdownBackfill() throws {
        let sessionURL = try makeSessionURL()
        let originalMarkdownURL = sessionURL.deletingPathExtension().appendingPathExtension("transcript.md")
        try """
        # 会议转写

        ## 逐条记录

        - [19:00:01] [最终] 原始实时转写，不应被覆盖
        """.write(to: originalMarkdownURL, atomically: true, encoding: .utf8)

        let segments = [
            DiarizedTranscriptSegment(
                beginMilliseconds: 0,
                endMilliseconds: 1_500,
                speakerID: "speaker-0",
                text: "第一位发言人介绍背景",
                chunkIndex: 0
            ),
            DiarizedTranscriptSegment(
                beginMilliseconds: 1_600,
                endMilliseconds: 3_000,
                speakerID: "speaker-1",
                text: "第二位发言人回应问题",
                chunkIndex: 0
            )
        ]

        let result = try DiarizationBackfillWriter.persist(
            segments: segments,
            sessionFileURL: sessionURL
        )

        try expect(FileManager.default.fileExists(atPath: result.diarizedJSONLURL.path), "diarized jsonl should exist")
        try expect(result.segmentCount == 2, "writer should report segment count")

        let jsonl = try String(contentsOf: result.diarizedJSONLURL, encoding: .utf8)
        try expect(jsonl.contains("\"speakerID\":\"speaker-0\""), "jsonl should include first speaker id")
        try expect(jsonl.contains("\"beginMilliseconds\":1600"), "jsonl should include session-relative timestamps")
        try expect(!jsonl.contains(NSHomeDirectory()), "jsonl should not contain absolute home path")

        let markdown = try String(contentsOf: originalMarkdownURL, encoding: .utf8)
        try expect(markdown.contains("## 说话人分离回填"), "markdown should include speaker backfill section")
        try expect(markdown.contains("[00:00:00.000 - 00:00:01.500] speaker-0：第一位发言人介绍背景"), "markdown should include first speaker line")
        try expect(markdown.contains("[00:00:01.600 - 00:00:03.000] speaker-1：第二位发言人回应问题"), "markdown should include second speaker line")
        try expect(markdown.contains("原始实时转写，不应被覆盖"), "markdown should preserve original transcript content")
    }

    private static func testProviderResultMergeThenBackfill() throws {
        let sessionURL = try makeSessionURL()
        let chunk = DiarizationAudioChunk(
            index: 3,
            startMilliseconds: 10_000,
            endMilliseconds: 20_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-3.wav"),
            state: .completed,
            taskID: "fake-task-3"
        )
        let providerResult = DiarizationChunkResult(
            chunk: chunk,
            sentences: [
                ProviderDiarizedSentence(
                    beginMilliseconds: 500,
                    endMilliseconds: 1_000,
                    speakerID: "speaker-a",
                    text: "provider 返回的第一句"
                ),
                ProviderDiarizedSentence(
                    beginMilliseconds: 1_500,
                    endMilliseconds: 2_000,
                    speakerID: "speaker-b",
                    text: "provider 返回的第二句"
                )
            ]
        )

        let merged = DiarizationMerger.merge(results: [providerResult])
        let result = try DiarizationBackfillWriter.persist(segments: merged, sessionFileURL: sessionURL)
        let jsonl = try String(contentsOf: result.diarizedJSONLURL, encoding: .utf8)
        let markdown = try String(contentsOf: result.transcriptMarkdownURL, encoding: .utf8)

        try expect(jsonl.contains("\"beginMilliseconds\":10500"), "provider chunk-local time should be converted before persistence")
        try expect(markdown.contains("[00:00:10.500 - 00:00:11.000] speaker-a：provider 返回的第一句"), "markdown should include merged provider first sentence")
        try expect(markdown.contains("[00:00:11.500 - 00:00:12.000] speaker-b：provider 返回的第二句"), "markdown should include merged provider second sentence")
    }

    private static func testBackfillLifecycleEvent() throws {
        let sessionURL = try makeSessionURL()
        let eventLogURL = sessionURL.deletingPathExtension().appendingPathExtension("events.log")
        let segments = [
            DiarizedTranscriptSegment(
                beginMilliseconds: 0,
                endMilliseconds: 500,
                speakerID: "speaker-0",
                text: "事件测试",
                chunkIndex: 0
            )
        ]

        _ = try DiarizationBackfillWriter.persist(
            segments: segments,
            sessionFileURL: sessionURL,
            eventLogURL: eventLogURL
        )

        let eventLog = try String(contentsOf: eventLogURL, encoding: .utf8)
        try expect(eventLog.contains("\"event\":\"diarization_backfill_saved\""), "event log should record backfill persistence")
        try expect(eventLog.contains("\"segments\":1"), "event log should include segment count")
        try expect(eventLog.contains("\"diarizedFile\":\"2026-05-23-19-00-00.diarized.jsonl\""), "event log should use safe file names")
        try expect(!eventLog.contains(NSHomeDirectory()), "event log should not contain absolute home path")
    }
}
