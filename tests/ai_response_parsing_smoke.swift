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

            print("AI response parsing smoke tests PASS")
        } catch {
            fputs("FAIL: unexpected error \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
