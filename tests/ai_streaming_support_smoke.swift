import Foundation

@main
struct AIStreamingSupportSmoke {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("[PASS] \(message)")
        } else {
            print("[FAIL] \(message)")
            failures += 1
        }
    }

    static func expectEqual(_ actual: String?, _ expected: String?, _ message: String) {
        expect(actual == expected, "\(message)（got: \(actual ?? "nil")）")
    }

    static func main() {
        // 1. 标准 delta.content 帧
        expectEqual(
            AIStreamingSupport.deltaText(fromSSELine: #"data: {"choices":[{"delta":{"content":"你好"}}]}"#),
            "你好",
            "标准 delta.content"
        )

        // 2. [DONE] 帧返回 nil
        expectEqual(AIStreamingSupport.deltaText(fromSSELine: "data: [DONE]"), nil, "[DONE] 帧返回 nil")

        // 3. 非 data 行（注释/空行/事件行）返回 nil
        expectEqual(AIStreamingSupport.deltaText(fromSSELine: ": keep-alive"), nil, "注释行返回 nil")
        expectEqual(AIStreamingSupport.deltaText(fromSSELine: ""), nil, "空行返回 nil")
        expectEqual(AIStreamingSupport.deltaText(fromSSELine: "event: message"), nil, "事件行返回 nil")

        // 4. reasoning_content 兜底（NVIDIA/Qwen 兼容）
        expectEqual(
            AIStreamingSupport.deltaText(fromSSELine: #"data: {"choices":[{"delta":{"reasoning_content":"思考"}}]}"#),
            "思考",
            "delta.reasoning_content 兜底"
        )

        // 5. content 优先于 reasoning_content
        expectEqual(
            AIStreamingSupport.deltaText(fromSSELine: #"data: {"choices":[{"delta":{"content":"正文","reasoning_content":"思考"}}]}"#),
            "正文",
            "content 优先"
        )

        // 6. 空 delta（role-only 帧）返回 nil
        expectEqual(
            AIStreamingSupport.deltaText(fromSSELine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#),
            nil,
            "role-only 帧返回 nil"
        )

        // 7. 整段 message 帧兼容
        expectEqual(
            AIStreamingSupport.deltaText(fromSSELine: #"data: {"choices":[{"message":{"content":"整段"}}]}"#),
            "整段",
            "message.content 帧兼容"
        )

        // 8. 坏 JSON 不崩溃
        expectEqual(AIStreamingSupport.deltaText(fromSSELine: "data: {broken"), nil, "坏 JSON 返回 nil")

        // 9. content 字段正则兜底：截断的 JSON
        expectEqual(
            AIStreamingSupport.fallbackContentField(from: #"{"should_speak": true, "content": "关键洞察在这里", "kind"#),
            "关键洞察在这里",
            "截断 JSON 的 content 兜底"
        )

        // 10. content 含转义字符
        expectEqual(
            AIStreamingSupport.fallbackContentField(from: #"{"content": "第一行\n\"引用\"", "kind": "insight"}"#),
            "第一行\n\"引用\"",
            "content 转义还原"
        )

        // 11. 无 content 字段返回 nil
        expectEqual(AIStreamingSupport.fallbackContentField(from: "完全不是 JSON 的文本"), nil, "无 content 字段返回 nil")

        // 12. should_speak 兜底
        expect(AIStreamingSupport.fallbackShouldSpeak(from: #"{"should_speak": false, "content"#) == false, "should_speak=false 兜底")
        expect(AIStreamingSupport.fallbackShouldSpeak(from: #"{"should_speak":true}"#) == true, "should_speak=true 兜底")
        expect(AIStreamingSupport.fallbackShouldSpeak(from: "无关文本") == nil, "无 should_speak 返回 nil")

        if failures > 0 {
            print("FAILED: \(failures) case(s)")
            exit(1)
        }
        print("All ai_streaming_support smoke cases passed")
    }
}
