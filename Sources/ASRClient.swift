import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ASRClient")

class ASRClient {
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var isConnected = false

    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// 连接 asr-bridge 的 /v1/stream WebSocket 端点
    func connect(port: Int) {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/v1/stream") else { return }
        logger.info("Connecting WebSocket to \(url)")
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        sendStart()
    }

    /// 发送 start 消息，告知 bridge 开始 ASR 会话
    private func sendStart() {
        let startMsg: [String: Any] = [
            "type": "start",
            "model": "qwen3-asr-flash-realtime",
            "sample_rate": 16000,
            "format": "pcm"
        ]
        sendJSON(startMsg) { [weak self] error in
            if let error {
                self?.onError?("start 消息发送失败: \(error.localizedDescription)")
            } else {
                // 立即允许发送音频，避免等待 "started" 事件期间丢失首秒数据
                // asr-bridge 会在 DashScope 握手完成前缓冲收到的音频
                self?.isConnected = true
                logger.info("start message sent, audio forwarding enabled")
                self?.receiveLoop()
            }
        }
    }

    private var audioChunkCount = 0

    /// 发送 PCM16 音频数据（Base64 编码）
    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        audioChunkCount += 1
        if audioChunkCount == 1 {
            logger.info("First audio chunk sent (\(data.count) bytes)")
        } else if audioChunkCount % 500 == 0 {
            logger.debug("Audio chunks sent: \(self.audioChunkCount)")
        }
        let audioMsg: [String: Any] = [
            "type": "audio",
            "data": data.base64EncodedString()
        ]
        sendJSON(audioMsg)
    }

    /// 发送 stop 消息，告知 bridge 录音结束
    private func sendStop() {
        let stopMsg: [String: Any] = ["type": "stop"]
        sendJSON(stopMsg)
    }

    func disconnect() {
        logger.info("Disconnecting (sent \(self.audioChunkCount) audio chunks total)")
        sendStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isConnected = false
            self?.webSocket?.cancel(with: .goingAway, reason: nil)
            self?.webSocket = nil
        }
    }

    // MARK: - Private

    private func sendJSON(_ dict: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            completion?(NSError(domain: "ASRClient", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "JSON 编码失败"]))
            return
        }
        webSocket?.send(.string(text)) { error in completion?(error) }
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
              let type = json["type"] as? String else { return }

        logger.debug("Bridge event: \(type)")
        switch type {
        case "started":
            isConnected = true
            logger.info("ASR session started")

        case "partial":
            if let partialText = json["text"] as? String, !partialText.isEmpty {
                logger.debug("partial: \(partialText)")
                onTranscript?(partialText, false)
            }

        case "final":
            if let finalText = json["text"] as? String, !finalText.isEmpty {
                logger.info("final: \(finalText)")
                onTranscript?(finalText, true)
            }

        case "finished":
            logger.info("ASR session finished")
            isConnected = false

        case "error":
            let errorMsg = json["error"] as? String ?? "unknown bridge error"
            onError?("ASR Bridge 错误: \(errorMsg)")

        default:
            break
        }
    }
}
