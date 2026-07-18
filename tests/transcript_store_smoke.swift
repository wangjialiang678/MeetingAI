import Foundation

enum TranscriptStoreSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct TranscriptStoreSmoke {
    static func main() {
        do {
            try testPartialOnlyEntriesProduceCompleteText()
            try testEmptyTextEntriesAreSkipped()
            try testImportedHistoricalEntriesAreExcluded()
            try testTimestampFormat()
            try testEmptyEntriesProduceEmptyText()
            try testTrimmerDropsCoveredPrefix()
            try testTrimmerNoCoverageKeepsSuffixLimitOnly()
            try testTrimmerFullCoverageKeepsMinimumTail()
            try testTrimmerShortTextUntouched()
            print("Transcript store smoke tests PASS")
        } catch {
            fputs("Transcript store smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TranscriptStoreSmokeFailure.failed(message)
        }
    }

    private static func date(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 18
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    private static func testPartialOnlyEntriesProduceCompleteText() throws {
        // partial-only 长会：.txt 也必须有完整内容，不再只认 final
        let entries = [
            TranscriptEntry(timestamp: date(15, 0, 1), text: "第一段还在临时状态的转写内容", isFinal: false),
            TranscriptEntry(timestamp: date(15, 1, 2), text: "第二段最终转写", isFinal: true),
            TranscriptEntry(timestamp: date(15, 2, 3), text: "第三段仍是 partial", isFinal: false)
        ]
        let text = TranscriptStore.completeTranscriptText(entries: entries)
        try expect(text.contains("第一段还在临时状态的转写内容"), "partial content must be included")
        try expect(text.contains("第二段最终转写"), "final content must be included")
        try expect(text.contains("第三段仍是 partial"), "trailing partial must be included")
        try expect(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 3, "one line per entry")
    }

    private static func testEmptyTextEntriesAreSkipped() throws {
        let entries = [
            TranscriptEntry(timestamp: date(15, 0, 1), text: "   ", isFinal: false),
            TranscriptEntry(timestamp: date(15, 0, 2), text: "有效内容", isFinal: true)
        ]
        let text = TranscriptStore.completeTranscriptText(entries: entries)
        try expect(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1, "blank entries should be skipped")
    }

    private static func testImportedHistoricalEntriesAreExcluded() throws {
        // 导入的历史转写（distantPast）不写入本场 .txt
        let entries = [
            TranscriptEntry(timestamp: .distantPast, text: "上一场会议导入的内容", isFinal: true),
            TranscriptEntry(timestamp: date(15, 0, 2), text: "本场内容", isFinal: false)
        ]
        let text = TranscriptStore.completeTranscriptText(entries: entries)
        try expect(!text.contains("上一场会议导入的内容"), "imported history must not enter this session's txt")
        try expect(text.contains("本场内容"), "current session content must be present")
    }

    private static func testTimestampFormat() throws {
        let entries = [TranscriptEntry(timestamp: date(9, 5, 7), text: "内容", isFinal: false)]
        let text = TranscriptStore.completeTranscriptText(entries: entries)
        try expect(text.hasPrefix("[09:05:07] "), "line should start with [HH:mm:ss] , got: \(text.prefix(15))")
    }

    private static func testEmptyEntriesProduceEmptyText() throws {
        try expect(TranscriptStore.completeTranscriptText(entries: []).isEmpty, "no entries should produce empty text")
    }

    // 活跃 partial 的覆盖裁剪（滚动替换显示层）
    private static func testTrimmerDropsCoveredPrefix() throws {
        let t0 = date(10, 0, 0)
        let text = String(repeating: "字", count: 1_000)
        // 覆盖到时间轴一半 → 约裁掉 50%*0.85=42.5% 前缀
        let visible = TranscriptDisplayTrimmer.visibleSuffix(
            text: text, firstTimestamp: t0, lastTimestamp: t0.addingTimeInterval(600),
            coverageCutoff: t0.addingTimeInterval(300)
        )
        try expect(visible.count < 1_000 && visible.count >= 500, "half coverage should trim conservatively, got \(visible.count)")
    }

    private static func testTrimmerNoCoverageKeepsSuffixLimitOnly() throws {
        let t0 = date(10, 0, 0)
        let text = String(repeating: "字", count: 1_000)
        let visible = TranscriptDisplayTrimmer.visibleSuffix(
            text: text, firstTimestamp: t0, lastTimestamp: t0.addingTimeInterval(600), coverageCutoff: nil
        )
        try expect(visible.count == 600, "no coverage should only apply max-chars suffix, got \(visible.count)")
    }

    private static func testTrimmerFullCoverageKeepsMinimumTail() throws {
        let t0 = date(10, 0, 0)
        let text = String(repeating: "字", count: 1_000)
        // 覆盖追平甚至超过 → 至少保留最小尾巴，不清空
        let visible = TranscriptDisplayTrimmer.visibleSuffix(
            text: text, firstTimestamp: t0, lastTimestamp: t0.addingTimeInterval(600),
            coverageCutoff: t0.addingTimeInterval(900)
        )
        try expect(!visible.isEmpty && visible.count <= 200, "full coverage should keep a small tail, got \(visible.count)")
    }

    private static func testTrimmerShortTextUntouched() throws {
        let t0 = date(10, 0, 0)
        let visible = TranscriptDisplayTrimmer.visibleSuffix(
            text: "短文本", firstTimestamp: t0, lastTimestamp: t0.addingTimeInterval(60),
            coverageCutoff: t0.addingTimeInterval(30)
        )
        try expect(visible == "短文本", "short text should stay visible, got \(visible)")
    }
}
