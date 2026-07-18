import Foundation

enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct ContextBuilderSmoke {
    static func main() {
        do {
            try testRecentDiscussionPriority()
            try testPinnedAndSummaryMemory()
            try testLatestAIOutputClamp()
            print("ContextBuilder smoke tests PASS")
        } catch {
            fputs("ContextBuilder smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SmokeFailure.failed(message)
        }
    }

    private static func testRecentDiscussionPriority() throws {
        let now = Date()
        let olderEntries = (0..<12).map { idx in
            TranscriptEntry(
                timestamp: now.addingTimeInterval(-(3600 + Double(idx * 90))),
                text: String(repeating: "早期议题\(idx) ", count: 18),
                isFinal: true
            )
        }
        let recentEntries = [
            TranscriptEntry(timestamp: now.addingTimeInterval(-900), text: "近期讨论聚焦商业模式和收费结构。", isFinal: true),
            TranscriptEntry(timestamp: now.addingTimeInterval(-700), text: "大家开始比较不同客户分层的策略。", isFinal: true)
        ]
        let hotEntries = [
            TranscriptEntry(timestamp: now.addingTimeInterval(-120), text: "最新问题是私董会里怎样快速指出盲点。", isFinal: true),
            TranscriptEntry(timestamp: now.addingTimeInterval(-20), text: "现在重点是让 AI 只在必要时开口。", isFinal: false)
        ]

        let rawTranscriptLength = (olderEntries + recentEntries + hotEntries).reduce(0) { $0 + $1.text.count }
        let snapshot = MeetingContextBuilder.buildSnapshot(
            transcriptEntries: olderEntries + recentEntries + hotEntries,
            insightCards: [],
            now: now
        )

        try expect(snapshot.promptText.contains("【最新讨论】"), "missing hot section")
        try expect(snapshot.promptText.contains("【近期背景】"), "missing recent section")
        try expect(snapshot.promptText.contains("【长期记忆】"), "missing durable section")
        try expect(snapshot.promptText.contains("只在必要时开口"), "missing latest discussion emphasis")
        try expect(snapshot.promptLength < rawTranscriptLength, "prompt not compacted")
        try expect(snapshot.hotEntryCount == 2, "unexpected hot entry count")
        try expect(snapshot.recentEntryCount == 2, "unexpected recent entry count")
    }

    private static func testPinnedAndSummaryMemory() throws {
        let now = Date()
        var pinned = InsightCard(content: "这是一个必须保留的关键盲点。", kind: .insight)
        pinned.isPinned = true
        let summary = InsightCard(content: "阶段小结：已经确认目标是做强旁听顾问。", kind: .summary)

        let snapshot = MeetingContextBuilder.buildSnapshot(
            transcriptEntries: [
                TranscriptEntry(timestamp: now.addingTimeInterval(-90), text: "最近讨论需要更强的洞察力。", isFinal: true)
            ],
            insightCards: [pinned, summary],
            now: now
        )

        try expect(snapshot.promptText.contains("关键盲点"), "missing pinned durable memory")
        try expect(snapshot.promptText.contains("阶段小结"), "missing summary durable memory")
        try expect(snapshot.durableMemoryItemCount >= 2, "unexpected durable item count")
    }

    private static func testLatestAIOutputClamp() throws {
        let longReply = String(repeating: "这是上一轮 AI 输出。", count: 80)
        let card = InsightCard(content: longReply, kind: .reply, userQuery: "上一轮说了什么？")

        let snapshot = MeetingContextBuilder.buildSnapshot(
            transcriptEntries: [],
            insightCards: [card]
        )

        try expect(snapshot.promptText.contains("【最近一次 AI 输出（避免重复）】"), "missing latest AI section")
        try expect(snapshot.promptLength < longReply.count + 120, "latest AI output not clamped")
    }
}
