import Foundation

func requireEqual(_ actual: String, _ expected: String, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

func data(_ json: String) -> Data {
    guard let value = json.data(using: .utf8) else {
        fputs("FAIL: could not encode test JSON\n", stderr)
        exit(1)
    }
    return value
}

@main
struct AIResponseParsingSmoke {
    static func main() {
        do {
            let standard = data(#"{"choices":[{"message":{"content":"hello"}}]}"#)
            requireEqual(
                try AIEngine.extractChatMessageText(from: standard),
                "hello",
                "standard message.content"
            )

            let nvidiaReasoning = data(#"{"choices":[{"message":{"role":"assistant","reasoning_content":"{\"ok\":true}"}}]}"#)
            requireEqual(
                try AIEngine.extractChatMessageText(from: nvidiaReasoning),
                #"{"ok":true}"#,
                "NVIDIA reasoning_content fallback"
            )

            let arrayContent = data(#"{"choices":[{"message":{"content":[{"type":"text","text":"part one"},{"type":"text","text":"part two"}]}}]}"#)
            requireEqual(
                try AIEngine.extractChatMessageText(from: arrayContent),
                "part one\npart two",
                "array content fallback"
            )

            let invalid = data(#"{"choices":[{"message":{"content":null}}]}"#)
            do {
                _ = try AIEngine.extractChatMessageText(from: invalid)
                fputs("FAIL: invalid response should throw\n", stderr)
                Foundation.exit(1)
            } catch {
                // Expected.
            }

            // 结构化 JSON 提取：GLM 等模型会把 JSON 包在 markdown 代码围栏里
            requireEqual(
                AIEngine.extractStructuredJSONText("{\"should_speak\": true}"),
                "{\"should_speak\": true}",
                "bare JSON passes through"
            )
            requireEqual(
                AIEngine.extractStructuredJSONText("```json\n{\"should_speak\": true}\n```"),
                "{\"should_speak\": true}",
                "json fence stripped"
            )
            requireEqual(
                AIEngine.extractStructuredJSONText("```\n{\"a\": 1}\n```"),
                "{\"a\": 1}",
                "anonymous fence stripped"
            )
            requireEqual(
                AIEngine.extractStructuredJSONText("好的，以下是结果：\n```json\n{\"a\": 1}\n```\n希望有帮助"),
                "{\"a\": 1}",
                "fence with surrounding prose stripped"
            )
            requireEqual(
                AIEngine.extractStructuredJSONText("前置说明 {\"a\": 1} 后置说明"),
                "{\"a\": 1}",
                "brace substring extracted from prose"
            )
            requireEqual(
                AIEngine.extractStructuredJSONText("纯文本，没有任何 JSON"),
                "纯文本，没有任何 JSON",
                "plain text unchanged"
            )

            print("AI response parsing smoke tests PASS")
        } catch {
            fputs("FAIL: unexpected error \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
