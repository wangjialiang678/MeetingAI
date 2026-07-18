import Foundation

/// 会议中逐分片转写纠错：用实时转写（qwen3-asr）交叉验证说话人分离转写（Fun-ASR），
/// 两个引擎错误互不相关。保守策略：只接受"文本替换"，句子数量/顺序/时间戳/说话人不许变；
/// 解析失败或结构不符一律返回原句，绝不阻塞回填展示。
enum TranscriptRefiner {
    static let realtimeContextBudget = 2_000

    static func buildSystemPrompt() -> String {
        """
        你是会议转写纠错器。给你同一时间窗的两份转写：
        A（参考）：实时流式转写片段，无说话人，可能有同音字错误但用词有时更准。
        B（待修）：说话人分离转写句子列表，质量通常更高，但可能有识别错误。
        任务：仅当你有高置信度判断 B 的某句存在明显识别错误（同音字、专有名词、数字）且 A 或上下文能佐证时，才修正该句文本。
        禁止：润色、改写、合并/拆分句子、增删信息、修改没有把握的内容。拿不准就保持原文。
        返回 JSON（不要包裹 markdown 代码块）：
        {"sentences": [{"index": 0, "text": "修正后文本"}, ...]}
        只输出有修改的句子；没有任何修改时返回 {"sentences": []}。
        """
    }

    static func buildUserContent(sentences: [ProviderDiarizedSentence], realtimeContext: String) -> String {
        let numbered = sentences.enumerated().map { index, sentence in
            "\(index). [\(sentence.speakerID)] \(sentence.text)"
        }.joined(separator: "\n")
        let context = String(realtimeContext.suffix(realtimeContextBudget))
        return """
        A（实时转写参考，可能截断）：
        \(context.isEmpty ? "（无）" : context)

        B（待修句子，按 index 引用）：
        \(numbered)
        """
    }

    /// 解析模型返回并应用修正。任何结构异常都退回原句。
    static func applyCorrections(_ raw: String, to original: [ProviderDiarizedSentence]) -> (sentences: [ProviderDiarizedSentence], corrections: Int) {
        let jsonText = AIEngine.extractStructuredJSONText(raw)
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["sentences"] as? [[String: Any]] else {
            return (original, 0)
        }

        var corrected = original
        var corrections = 0
        for item in items {
            guard let index = item["index"] as? Int,
                  let text = item["text"] as? String,
                  original.indices.contains(index) else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != original[index].text else { continue }
            let source = original[index]
            corrected[index] = ProviderDiarizedSentence(
                beginMilliseconds: source.beginMilliseconds,
                endMilliseconds: source.endMilliseconds,
                speakerID: source.speakerID,
                text: trimmed
            )
            corrections += 1
        }
        return (corrected, corrections)
    }
}
