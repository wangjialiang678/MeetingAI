import Foundation

enum DiarizationSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct DiarizationMergeSmoke {
    static func main() {
        do {
            try testSessionRelativeTimestamps()
            try testOutOfOrderTaskCompletion()
            try testOverlapDeduplication()
            try testTouchingIntervalsAreNotDeduplicated()
            try testDifferentSpeakersInOverlapAreNotDeduplicated()
            print("Diarization merge smoke tests PASS")
        } catch {
            fputs("Diarization merge smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw DiarizationSmokeFailure.failed(message)
        }
    }

    private static func testSessionRelativeTimestamps() throws {
        let chunk = DiarizationAudioChunk(
            index: 2,
            startMilliseconds: 60_000,
            endMilliseconds: 90_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-2.wav")
        )
        let sentence = ProviderDiarizedSentence(
            beginMilliseconds: 1_200,
            endMilliseconds: 3_400,
            speakerID: "speaker-0",
            text: "这里是第二个分片里的句子"
        )

        let merged = DiarizationMerger.merge(results: [
            DiarizationChunkResult(chunk: chunk, sentences: [sentence])
        ])

        try expect(merged.count == 1, "expected one merged sentence")
        try expect(merged[0].beginMilliseconds == 61_200, "begin time should include chunk offset")
        try expect(merged[0].endMilliseconds == 63_400, "end time should include chunk offset")
        try expect(merged[0].speakerID == "speaker-0", "speaker id should be preserved")
        try expect(merged[0].chunkIndex == 2, "chunk index should be preserved")
    }

    private static func testOutOfOrderTaskCompletion() throws {
        let laterChunk = DiarizationAudioChunk(
            index: 1,
            startMilliseconds: 30_000,
            endMilliseconds: 60_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-1.wav")
        )
        let earlierChunk = DiarizationAudioChunk(
            index: 0,
            startMilliseconds: 0,
            endMilliseconds: 30_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-0.wav")
        )

        let merged = DiarizationMerger.merge(results: [
            DiarizationChunkResult(
                chunk: laterChunk,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 1_000,
                        endMilliseconds: 2_000,
                        speakerID: "speaker-1",
                        text: "后完成的后半段"
                    )
                ]
            ),
            DiarizationChunkResult(
                chunk: earlierChunk,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 20_000,
                        endMilliseconds: 21_000,
                        speakerID: "speaker-0",
                        text: "先发生的前半段"
                    )
                ]
            )
        ])

        try expect(merged.map(\.text) == ["先发生的前半段", "后完成的后半段"], "merged output should be sorted by session time")
    }

    private static func testOverlapDeduplication() throws {
        let first = DiarizationAudioChunk(
            index: 0,
            startMilliseconds: 0,
            endMilliseconds: 60_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-0.wav")
        )
        let second = DiarizationAudioChunk(
            index: 1,
            startMilliseconds: 55_000,
            endMilliseconds: 115_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-1.wav")
        )

        let merged = DiarizationMerger.merge(results: [
            DiarizationChunkResult(
                chunk: first,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 54_000,
                        endMilliseconds: 57_000,
                        speakerID: "speaker-0",
                        text: "这个句子位于重叠区域"
                    )
                ]
            ),
            DiarizationChunkResult(
                chunk: second,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 0,
                        endMilliseconds: 3_000,
                        speakerID: "speaker-0",
                        text: "这个句子位于重叠区域"
                    ),
                    ProviderDiarizedSentence(
                        beginMilliseconds: 4_000,
                        endMilliseconds: 6_000,
                        speakerID: "speaker-1",
                        text: "第二个分片的新句子"
                    )
                ]
            )
        ])

        try expect(merged.map(\.text) == ["这个句子位于重叠区域", "第二个分片的新句子"], "duplicate overlap sentence should be removed")
        try expect(merged[0].chunkIndex == 1, "overlap duplicate should prefer later chunk")
    }

    private static func testTouchingIntervalsAreNotDeduplicated() throws {
        let first = DiarizationAudioChunk(
            index: 0,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-0.wav")
        )
        let second = DiarizationAudioChunk(
            index: 1,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-1.wav")
        )

        let merged = DiarizationMerger.merge(results: [
            DiarizationChunkResult(
                chunk: first,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 0,
                        endMilliseconds: 1_000,
                        speakerID: "speaker-0",
                        text: "收到"
                    )
                ]
            ),
            DiarizationChunkResult(
                chunk: second,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 0,
                        endMilliseconds: 1_000,
                        speakerID: "speaker-0",
                        text: "收到"
                    )
                ]
            )
        ])

        try expect(merged.count == 2, "touching intervals with repeated text should remain separate sentences")
        try expect(merged.map(\.beginMilliseconds) == [0, 1_000], "touching intervals should preserve both session-relative positions")
    }

    private static func testDifferentSpeakersInOverlapAreNotDeduplicated() throws {
        let first = DiarizationAudioChunk(
            index: 0,
            startMilliseconds: 0,
            endMilliseconds: 60_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-0.wav")
        )
        let second = DiarizationAudioChunk(
            index: 1,
            startMilliseconds: 55_000,
            endMilliseconds: 115_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-1.wav")
        )

        let merged = DiarizationMerger.merge(results: [
            DiarizationChunkResult(
                chunk: first,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 54_000,
                        endMilliseconds: 57_000,
                        speakerID: "speaker-0",
                        text: "对"
                    )
                ]
            ),
            DiarizationChunkResult(
                chunk: second,
                sentences: [
                    ProviderDiarizedSentence(
                        beginMilliseconds: 0,
                        endMilliseconds: 3_000,
                        speakerID: "speaker-1",
                        text: "对"
                    )
                ]
            )
        ])

        try expect(merged.count == 2, "same text from different speakers in overlap window must not be merged")
        try expect(Set(merged.map(\.speakerID)) == ["speaker-0", "speaker-1"], "both speakers should survive the merge")
    }
}
