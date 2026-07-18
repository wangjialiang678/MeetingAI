import Foundation

enum TranscriptRefinerSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct TranscriptRefinerSmoke {
    static func main() {
        do {
            try testPromptContainsBothSources()
            try testValidCorrectionApplied()
            try testFencedResponseAccepted()
            try testInvalidResponseKeepsOriginal()
            try testOutOfRangeIndexIgnored()
            try testTimingAndSpeakerPreserved()
            try testRealtimeContextTruncated()
            print("Transcript refiner smoke tests PASS")
        } catch {
            fputs("Transcript refiner smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TranscriptRefinerSmokeFailure.failed(message)
        }
    }

    private static func sampleSentences() -> [ProviderDiarizedSentence] {
        [
            ProviderDiarizedSentence(beginMilliseconds: 0, endMilliseconds: 2_000, speakerID: "speaker-0", text: "我们先讨论鸡屋的定价"),
            ProviderDiarizedSentence(beginMilliseconds: 2_100, endMilliseconds: 4_000, speakerID: "speaker-1", text: "同意，先看竞品区间")
        ]
    }

    private static func testPromptContainsBothSources() throws {
        let user = TranscriptRefiner.buildUserContent(
            sentences: sampleSentences(),
            realtimeContext: "我们先讨论机会的定价"
        )
        try expect(user.contains("机会的定价"), "user content should carry realtime reference")
        try expect(user.contains("0. [speaker-0]"), "user content should number sentences with speaker")
        let system = TranscriptRefiner.buildSystemPrompt()
        try expect(system.contains("高置信度"), "system prompt must state conservative bar")
        try expect(system.contains("禁止"), "system prompt must forbid rewriting")
    }

    private static func testValidCorrectionApplied() throws {
        let response = #"{"sentences": [{"index": 0, "text": "我们先讨论机会的定价"}]}"#
        let (result, count) = TranscriptRefiner.applyCorrections(response, to: sampleSentences())
        try expect(count == 1, "one correction should be applied")
        try expect(result[0].text == "我们先讨论机会的定价", "corrected text should replace original")
        try expect(result[1].text == "同意，先看竞品区间", "untouched sentence stays")
    }

    private static func testFencedResponseAccepted() throws {
        let response = "```json\n{\"sentences\": [{\"index\": 1, \"text\": \"同意，先看竞品价格区间\"}]}\n```"
        let (result, count) = TranscriptRefiner.applyCorrections(response, to: sampleSentences())
        try expect(count == 1 && result[1].text == "同意，先看竞品价格区间", "fenced JSON should be parsed")
    }

    private static func testInvalidResponseKeepsOriginal() throws {
        let (result, count) = TranscriptRefiner.applyCorrections("抱歉我无法完成该任务", to: sampleSentences())
        try expect(count == 0, "non-JSON should apply nothing")
        try expect(result.map(\.text) == sampleSentences().map(\.text), "original sentences must be preserved")
    }

    private static func testOutOfRangeIndexIgnored() throws {
        let response = #"{"sentences": [{"index": 9, "text": "越界"}, {"index": -1, "text": "越界"}]}"#
        let (result, count) = TranscriptRefiner.applyCorrections(response, to: sampleSentences())
        try expect(count == 0 && result.map(\.text) == sampleSentences().map(\.text), "out-of-range indexes must be ignored")
    }

    private static func testTimingAndSpeakerPreserved() throws {
        let response = #"{"sentences": [{"index": 0, "text": "我们先讨论机会的定价"}]}"#
        let (result, _) = TranscriptRefiner.applyCorrections(response, to: sampleSentences())
        try expect(result[0].beginMilliseconds == 0 && result[0].endMilliseconds == 2_000, "timing must not change")
        try expect(result[0].speakerID == "speaker-0", "speaker must not change")
    }

    private static func testRealtimeContextTruncated() throws {
        let longContext = String(repeating: "很长的上下文", count: 1_000)
        let user = TranscriptRefiner.buildUserContent(sentences: sampleSentences(), realtimeContext: longContext)
        try expect(user.count < longContext.count, "oversized realtime context must be truncated")
    }
}
