import Foundation

enum TranscriptMarkdownWriter {
    static func writeSnapshot(
        entries: [TranscriptEntry],
        speakerBackfillSegments: [DiarizedTranscriptSegment],
        to url: URL,
        generatedAt: Date = Date()
    ) throws {
        let existingMarkdown = try? String(contentsOf: url, encoding: .utf8)
        let markdown = renderSnapshot(
            entries: entries,
            speakerBackfillSegments: speakerBackfillSegments,
            generatedAt: generatedAt,
            existingMarkdown: existingMarkdown
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    static func renderSnapshot(
        entries: [TranscriptEntry],
        speakerBackfillSegments: [DiarizedTranscriptSegment],
        generatedAt: Date = Date(),
        existingMarkdown: String? = nil
    ) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let fullFormatter = DateFormatter()
        fullFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let finalCount = entries.filter(\.isFinal).count
        let partialCount = entries.count - finalCount
        var lines: [String] = [
            "# 会议转写",
            "",
            "- 生成时间：\(fullFormatter.string(from: generatedAt))",
            "- 条目数：\(entries.count)",
            "- 最终：\(finalCount)",
            "- 临时：\(partialCount)",
            "",
            "## 逐条记录",
            ""
        ]

        if entries.isEmpty {
            lines.append("_暂无转写_")
        } else {
            for entry in entries {
                let timestamp = entry.timestamp == .distantPast ? "导入" : timeFormatter.string(from: entry.timestamp)
                let status = entry.isFinal ? "最终" : "临时"
                let text = entry.text.replacingOccurrences(of: "\n", with: " ")
                lines.append("- [\(timestamp)] [\(status)] \(text)")
            }
        }

        if !speakerBackfillSegments.isEmpty {
            lines.append("")
            lines.append(contentsOf: renderSpeakerBackfillBlock(segments: speakerBackfillSegments))
        } else if let preservedBackfill = extractSpeakerBackfillBlock(from: existingMarkdown) {
            lines.append("")
            lines.append(preservedBackfill)
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func renderSpeakerBackfillBlock(segments: [DiarizedTranscriptSegment]) -> [String] {
        var lines = ["## 说话人分离回填", ""]
        for segment in segments.sorted(by: speakerSegmentSort) {
            let text = segment.text.replacingOccurrences(of: "\n", with: " ")
            lines.append("- [\(formatMilliseconds(segment.beginMilliseconds)) - \(formatMilliseconds(segment.endMilliseconds))] \(segment.speakerID)：\(text)")
        }
        return lines
    }

    private static func speakerSegmentSort(
        lhs: DiarizedTranscriptSegment,
        rhs: DiarizedTranscriptSegment
    ) -> Bool {
        if lhs.beginMilliseconds != rhs.beginMilliseconds {
            return lhs.beginMilliseconds < rhs.beginMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.chunkIndex < rhs.chunkIndex
    }

    private static func extractSpeakerBackfillBlock(from markdown: String?) -> String? {
        guard let markdown, !markdown.isEmpty else { return nil }
        guard let range = markdown.range(of: "\n## 说话人分离回填") else {
            if markdown.hasPrefix("## 说话人分离回填") {
                return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        let block = String(markdown[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? nil : block
    }

    private static func formatMilliseconds(_ milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        let totalSeconds = clamped / 1_000
        let ms = clamped % 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, ms)
    }
}
