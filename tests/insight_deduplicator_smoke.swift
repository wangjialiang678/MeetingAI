import Foundation

enum InsightDeduplicatorSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct InsightDeduplicatorSmoke {
    static func main() {
        do {
            try testIdenticalTextIsDuplicate()
            try testMinorFormattingDifferenceIsDuplicate()
            try testDifferentContentIsNotDuplicate()
            try testOnlyRecentWindowIsConsidered()
            try testEmptyCandidateIsNotDuplicate()
            print("Insight deduplicator smoke tests PASS")
        } catch {
            fputs("Insight deduplicator smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw InsightDeduplicatorSmokeFailure.failed(message)
        }
    }

    private static func testIdenticalTextIsDuplicate() throws {
        let text = "当前讨论集中在定价策略上，建议先调研竞品的价格区间，再决定是否降价。"
        let similarity = InsightDeduplicator.duplicateSimilarity(
            candidate: text,
            recentInsights: [text]
        )
        try expect(similarity != nil, "identical insight should be detected as duplicate")
        try expect(similarity! > 0.99, "identical insight similarity should be ~1.0, got \(similarity!)")
    }

    private static func testMinorFormattingDifferenceIsDuplicate() throws {
        let previous = "当前讨论集中在定价策略上，建议先调研竞品的价格区间，再决定是否降价。"
        let candidate = "当前讨论集中在定价策略上。建议先调研竞品的价格区间，再决定是否降价"
        let similarity = InsightDeduplicator.duplicateSimilarity(
            candidate: candidate,
            recentInsights: [previous]
        )
        try expect(similarity != nil, "punctuation/whitespace-only variation should be detected as duplicate")
    }

    private static func testDifferentContentIsNotDuplicate() throws {
        let previous = "当前讨论集中在定价策略上，建议先调研竞品的价格区间。"
        let candidate = "团队开始讨论下个季度的招聘计划，重点是后端工程师缺口。"
        let similarity = InsightDeduplicator.duplicateSimilarity(
            candidate: candidate,
            recentInsights: [previous]
        )
        try expect(similarity == nil, "unrelated insight should not be flagged as duplicate")
    }

    private static func testOnlyRecentWindowIsConsidered() throws {
        let old = "会议开场时提到的老话题，早已翻篇。这段内容只在窗口之外出现过一次。"
        let fillers = [
            "第一条新洞察：讨论了产品发布时间表和依赖项。",
            "第二条新洞察：确定了市场推广的两个渠道。",
            "第三条新洞察：预算分配需要下周财务确认。"
        ]
        let similarity = InsightDeduplicator.duplicateSimilarity(
            candidate: old,
            recentInsights: [old] + fillers,
            window: 3
        )
        try expect(similarity == nil, "insight outside the recent window should not block new output")
    }

    private static func testEmptyCandidateIsNotDuplicate() throws {
        let similarity = InsightDeduplicator.duplicateSimilarity(
            candidate: "",
            recentInsights: ["任何已有洞察内容"]
        )
        try expect(similarity == nil, "empty candidate should not be treated as duplicate")
    }
}
