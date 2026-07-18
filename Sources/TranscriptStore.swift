import Foundation

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
