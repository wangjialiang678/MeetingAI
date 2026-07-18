import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ASRClient")

class ASRClient {
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let stateQueue = DispatchQueue(label: "MeetingAI.ASRClient.state")
    private var isConnected = false
    private var isDisconnecting = false

    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onEvent: ((String, [String: String]) -> Void)?

    /// 连接 asr-bridge 的 /v1/stream WebSocket 端点
    func connect(port: Int) {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/v1/stream") else { return }
        logger.info("Connecting WebSocket to \(url)")
        onEvent?("connect_requested", ["url": url.absoluteString])
        let task = session.webSocketTask(with: url)
        stateQueue.async { [weak self] in
            self?.webSocket = task
            self?.isDisconnecting = false
        }
        task.resume()
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
                self?.onEvent?("start_failed", ["error": error.localizedDescription])
                self?.onError?("start 消息发送失败: \(error.localizedDescription)")
            } else {
                // 立即允许发送音频，避免等待 "started" 事件期间丢失首秒数据
                // asr-bridge 会在 DashScope 握手完成前缓冲收到的音频
                self?.stateQueue.async { [weak self] in
                    guard let self, !self.isDisconnecting else { return }
                    self.isConnected = true
                }
                logger.info("start message sent, audio forwarding enabled")
                self?.onEvent?("start_sent", [:])
                self?.receiveLoop()
            }
        }
    }

    private var audioChunkCount = 0

    /// 发送 PCM16 音频数据（Base64 编码）
    func sendAudio(_ data: Data) {
        stateQueue.async { [weak self] in
            guard let self, self.isConnected, !self.isDisconnecting else { return }
            self.audioChunkCount += 1
            if self.audioChunkCount == 1 {
                logger.info("First audio chunk sent (\(data.count) bytes)")
                self.onEvent?("first_audio_chunk_sent", ["bytes": String(data.count)])
            } else if self.audioChunkCount % 500 == 0 {
                logger.debug("Audio chunks sent: \(self.audioChunkCount)")
            }
            let audioMsg: [String: Any] = [
                "type": "audio",
                "data": data.base64EncodedString()
            ]
            self.sendJSONOnStateQueue(audioMsg)
        }
    }

    /// 发送 stop 消息，告知 bridge 录音结束
    private func stopMessageData() -> String? {
        let stopMsg: [String: Any] = ["type": "stop"]
        guard let data = try? JSONSerialization.data(withJSONObject: stopMsg),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    func disconnect(gracePeriod: TimeInterval = 0.8, completion: (() -> Void)? = nil) {
        stateQueue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            guard !self.isDisconnecting else {
                completion?()
                return
            }
            self.isDisconnecting = true
            self.isConnected = false
            let audioChunks = self.audioChunkCount
            let task = self.webSocket
            logger.info("Disconnecting (sent \(audioChunks) audio chunks total)")
            self.onEvent?("disconnect_requested", ["audioChunks": String(audioChunks)])

            if let stopText = self.stopMessageData() {
                task?.send(.string(stopText)) { [weak self] error in
                    if let error {
                        self?.onEvent?("stop_send_failed", ["error": error.localizedDescription])
                    } else {
                        self?.onEvent?("stop_sent", [:])
                    }
                }
            }

            self.stateQueue.asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                task?.cancel(with: .goingAway, reason: nil)
                if self.webSocket === task {
                    self.webSocket = nil
                }
                self.onEvent?("disconnected", ["graceSeconds": String(format: "%.1f", gracePeriod)])
                completion?()
            }
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
        stateQueue.async { [weak self] in
            self?.webSocket?.send(.string(text)) { error in completion?(error) }
        }
    }

    private func sendJSONOnStateQueue(_ dict: [String: Any], completion: ((Error?) -> Void)? = nil) {
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
                self?.onEvent?("receive_failed", ["error": error.localizedDescription])
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
            stateQueue.async { [weak self] in
                guard let self, !self.isDisconnecting else { return }
                self.isConnected = true
            }
            logger.info("ASR session started")
            onEvent?("session_started", [:])

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
            stateQueue.async { [weak self] in
                self?.isConnected = false
            }
            onEvent?("session_finished", [:])

        case "error":
            let errorMsg = json["error"] as? String ?? "unknown bridge error"
            onEvent?("bridge_error", ["error": errorMsg])
            onError?("ASR Bridge 错误: \(errorMsg)")

        default:
            break
        }
    }
}
