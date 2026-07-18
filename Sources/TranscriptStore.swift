import Foundation

/// 滚动替换的显示层裁剪：活跃 partial 会累积整场文本，其中已被说话人段落覆盖的
/// 前缀应从"实时尾巴"里裁掉。partial 内部无逐字时间戳，按时间比例估算并乘 0.85
/// 保守系数（语速不均，宁少裁不多裁）；只影响显示，落盘数据不动。
enum TranscriptDisplayTrimmer {
    static let minimumVisibleTail = 60

    static func visibleSuffix(
        text: String,
        firstTimestamp: Date,
        lastTimestamp: Date,
        coverageCutoff: Date?,
        maxChars: Int = 600
    ) -> String {
        var result = text
        if let cutoff = coverageCutoff,
           cutoff > firstTimestamp,
           lastTimestamp > firstTimestamp {
            let coveredFraction = min(1.0, cutoff.timeIntervalSince(firstTimestamp) / lastTimestamp.timeIntervalSince(firstTimestamp))
            var dropCount = Int(Double(result.count) * coveredFraction * 0.85)
            dropCount = min(dropCount, max(0, result.count - minimumVisibleTail))
            if dropCount > 0 {
                result = String(result.suffix(result.count - dropCount))
            }
        }
        if result.count > maxChars {
            result = String(result.suffix(maxChars))
        }
        return result
    }
}

/// 会后完整转写文本构建。
/// 真实会议中 final 可能极少（观测过 6917 partial 对 2 final），
/// `.txt` 若只收 final 会名存实亡；停止会议时用全部 entries（partial + final）重写为完整版。
enum TranscriptStore {
    static func completeTranscriptText(entries: [TranscriptEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines = entries.compactMap { entry -> String? in
            // 导入的历史转写（distantPast）属于上一场，不写入本场 .txt
            guard entry.timestamp != .distantPast else { return nil }
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(formatter.string(from: entry.timestamp))] \(text)"
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }
}
