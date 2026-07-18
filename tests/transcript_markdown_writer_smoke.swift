import Foundation

enum TranscriptMarkdownWriterSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct TranscriptMarkdownWriterSmoke {
    static func main() {
        do {
            try testSnapshotPreservesExistingSpeakerBackfillWhenSegmentsAreNotReady()
            try testSnapshotReplacesSpeakerBackfillWhenSegmentsAreAvailable()
            print("Transcript markdown writer smoke tests PASS")
        } catch {
            fputs("Transcript markdown writer smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TranscriptMarkdownWriterSmokeFailure.failed(message)
        }
    }

    private static func testSnapshotPreservesExistingSpeakerBackfillWhenSegmentsAreNotReady() throws {
        let existing = """
        # 会议转写

        ## 逐条记录

        - [10:00:00] [最终] 旧内容

        ## 说话人分离回填

        - [00:00:01.000 - 00:00:02.000] speaker-0：已经回填的说话人内容

        """
        let entries = [
            TranscriptEntry(timestamp: Date(timeIntervalSince1970: 100), text: "新的实时转写", isFinal: true)
        ]

        let markdown = TranscriptMarkdownWriter.renderSnapshot(
            entries: entries,
            speakerBackfillSegments: [],
            generatedAt: Date(timeIntervalSince1970: 200),
            existingMarkdown: existing
        )

        try expect(markdown.contains("新的实时转写"), "snapshot should include current transcript entries")
        try expect(markdown.contains("## 说话人分离回填"), "snapshot should keep existing speaker backfill heading")
        try expect(markdown.contains("已经回填的说话人内容"), "snapshot should preserve existing speaker backfill body")
    }

    private static func testSnapshotReplacesSpeakerBackfillWhenSegmentsAreAvailable() throws {
        let existing = """
        # 会议转写

        ## 说话人分离回填

        - [00:00:01.000 - 00:00:02.000] speaker-0：旧回填

        """
        let entries = [
            TranscriptEntry(timestamp: Date(timeIntervalSince1970: 100), text: "新的实时转写", isFinal: true)
        ]
        let segments = [
            DiarizedTranscriptSegment(
                beginMilliseconds: 2_000,
                endMilliseconds: 3_000,
                speakerID: "speaker-1",
                text: "新的说话人回填",
                chunkIndex: 1
            )
        ]

        let markdown = TranscriptMarkdownWriter.renderSnapshot(
            entries: entries,
            speakerBackfillSegments: segments,
            generatedAt: Date(timeIntervalSince1970: 200),
            existingMarkdown: existing
        )

        try expect(markdown.contains("新的说话人回填"), "snapshot should render fresh speaker backfill")
        try expect(!markdown.contains("旧回填"), "snapshot should replace stale speaker backfill")
    }
}
