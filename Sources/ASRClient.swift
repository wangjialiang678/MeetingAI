import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ASRClient")

class ASRClient {
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let taskId: String

    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    init() {
        taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
    }

    func connect(port: Int) {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/api-ws/v1/inference") else { return }
        logger.info("Connecting WebSocket to \(url)")
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        sendRunTask()
        receiveLoop()
    }

    private func sendRunTask() {
        let runTask: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskId,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": "",
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16000,
                    "language_hints": ["zh"]
                ] as [String: Any],
                "input": [:] as [String: Any]
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: runTask),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(jsonString)) { [weak self] error in
            if let error { self?.onError?("run-task 发送失败: \(error.localizedDescription)") }
        }
    }

    func sendAudio(_ data: Data) {
        webSocket?.send(.data(data)) { _ in }
    }

    func sendFinishTask() {
        let finishTask: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskId
            ],
            "payload": [:] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: finishTask),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(jsonString)) { _ in }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self?.handleMessage(text)
                }
                self?.receiveLoop()
            case .failure(let error):
                self?.onError?("WebSocket 接收错误: \(error.localizedDescription)")
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else { return }

        logger.debug("WS event: \(event)")
        switch event {
        case "result-generated":
            if let payload = json["payload"] as? [String: Any],
               let output = payload["output"] as? [String: Any],
               let sentence = output["sentence"] as? [String: Any],
               let recognizedText = sentence["text"] as? String {
                let isFinal = sentence["sentence_end"] as? Bool ?? false
                onTranscript?(recognizedText, isFinal)
            }
        case "task-failed":
            if let payload = json["payload"] as? [String: Any],
               let output = payload["output"] as? [String: Any],
               let message = output["message"] as? String {
                onError?("ASR 错误: \(message)")
            }
        default:
            break
        }
    }

    func disconnect() {
        sendFinishTask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.webSocket?.cancel(with: .goingAway, reason: nil)
            self?.webSocket = nil
        }
    }
}
