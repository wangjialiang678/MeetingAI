import Foundation

/// SSE 流式响应解析与结构化输出容错兜底（纯函数，无网络依赖，便于 smoke 测试）
enum AIStreamingSupport {
    /// 解析一行 SSE：返回该行携带的增量文本；非数据行、[DONE]、无文本增量时返回 nil
    static func deltaText(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty { return content }
            // 部分 OpenAI-compatible 网关把正文放 reasoning_content（与非流式行为一致，勿回退）
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { return reasoning }
            return nil
        }
        // 兼容个别网关在流式帧里放整段 message
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        return nil
    }

    /// 结构化 JSON 解析失败时的正则兜底：从原始文本抠出 "content" 字段值（含转义还原）
    static func fallbackContentField(from raw: String) -> String? {
        let pattern = #""content"\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        let escaped = String(raw[range])
        guard !escaped.isEmpty else { return nil }
        let jsonFragment = "\"\(escaped)\""
        if let data = jsonFragment.data(using: .utf8),
           let unescaped = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
           !unescaped.isEmpty {
            return unescaped
        }
        return escaped
    }

    /// should_speak 的正则兜底；解析不出返回 nil
    static func fallbackShouldSpeak(from raw: String) -> Bool? {
        let pattern = #""should_speak"\s*:\s*(true|false)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        return raw[range] == "true"
    }
}
