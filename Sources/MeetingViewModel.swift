import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ViewModel")

@MainActor
class MeetingViewModel: ObservableObject {
    @Published var transcriptEntries: [TranscriptEntry] = []
    @Published var chatMessages: [ChatMessage] = []
    @Published var isRecording = false
    @Published var isServerRunning = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var userInput = ""
    @Published var isAnalyzing = false

    private var audioRecorder: AudioRecorder?
    private var asrClient: ASRClient?
    private var aiEngine: AIEngine?
    private var serverManager: ASRServerManager?

    // Timers
    private var durationTimer: Timer?
    private var silenceCheckTimer: Timer?

    private let config: AppConfig

    // Step A: Session file saving
    private var sessionFileURL: URL?

    // Step D: ASR reconnect
    private var asrReconnectCount = 0
    private let maxASRReconnects = 3

    // Step E: Smart trigger state
    private var lastAnalysisEntryCount = 0
    private var lastTranscriptTime = Date.distantPast
    private var lastAnalysisTime = Date.distantPast
    private var analysisCount = 0

    init() {
        config = AppConfig.load()
        logger.info("Config loaded: ASR port=\(self.config.asrServerPort), AI model=\(self.config.aiModel)")
        logger.info("DashScope key: \(self.config.dashscopeAPIKey.prefix(8))..., MiniMax key: \(self.config.minimaxAPIKey.prefix(8))...")
    }

    func startMeeting() async {
        logger.info("Starting meeting...")

        // 1. Start ASR server
        serverManager = ASRServerManager(port: config.asrServerPort, apiKey: config.dashscopeAPIKey)
        do {
            try await serverManager!.start()
            isServerRunning = true
        } catch {
            appendChat(.system, "ASR 服务启动失败: \(error.localizedDescription)")
            return
        }

        // 2. Setup AI engine
        aiEngine = AIEngine(apiKey: config.minimaxAPIKey, model: config.aiModel, baseURL: config.minimaxBaseURL)

        // 3. Setup ASR client
        let client = ASRClient()
        client.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor [weak self] in
                self?.handleTranscript(text: text, isFinal: isFinal)
            }
        }
        client.onError = { [weak self] errorMsg in
            Task { @MainActor [weak self] in
                self?.handleASRError(errorMsg)
            }
        }
        client.connect(port: config.asrServerPort)
        asrClient = client

        // Reset state
        asrReconnectCount = 0
        analysisCount = 0
        lastAnalysisEntryCount = 0
        lastAnalysisTime = .distantPast
        lastTranscriptTime = .distantPast

        // Step A: Create session file (and derive MP3 URL from same base)
        createSessionFile()
        let mp3URL = sessionFileURL?.deletingPathExtension().appendingPathExtension("mp3")

        // 4. Start recording
        let recorder = AudioRecorder()
        recorder.onAudioData = { [weak self] data in
            self?.asrClient?.sendAudio(data)
        }
        do {
            try recorder.start(recordingURL: mp3URL)
        } catch {
            appendChat(.system, "录音启动失败: \(error.localizedDescription)")
            return
        }
        audioRecorder = recorder
        isRecording = true

        // 5. Start timers
        startTimers()

        appendChat(.system, "会议已开始，AI 将在沉默或内容积累时自动分析。点击 ⚡ 可随时手动触发分析。")
    }

    func stopMeeting() {
        logger.info("Stopping meeting...")
        stopTimers()

        let savedMP3 = audioRecorder?.recordingURL
        audioRecorder?.stop()
        audioRecorder = nil

        asrClient?.disconnect()
        asrClient = nil
        serverManager?.stop()
        serverManager = nil
        isRecording = false
        isServerRunning = false
        recordingDuration = 0

        let savedTxt = sessionFileURL

        // Reset state
        analysisCount = 0
        lastAnalysisEntryCount = 0
        lastAnalysisTime = .distantPast
        sessionFileURL = nil

        var msg = "会议已结束"
        if let mp3 = savedMP3 { msg += "\n录音：\(mp3.path)" }
        if let txt = savedTxt { msg += "\n转写：\(txt.path)" }
        appendChat(.system, msg)
    }

    func triggerAnalysis() {
        guard isRecording, !isAnalyzing else {
            if !isRecording { appendChat(.system, "请先开始会议") }
            return
        }
        let finalCount = transcriptEntries.filter(\.isFinal).count
        guard finalCount > lastAnalysisEntryCount else {
            appendChat(.system, "暂无新转写内容可分析")
            return
        }

        analysisCount += 1
        isAnalyzing = true
        lastAnalysisEntryCount = finalCount
        lastAnalysisTime = Date()

        let customPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt")
            .flatMap { $0.isEmpty ? nil : $0 }
        let systemPrompt = customPrompt ?? Self.buildDefaultSystemPrompt(
            count: analysisCount, elapsedMin: Int(recordingDuration / 60)
        )
        let userContent = buildAnalysisUserContent()

        logger.info("Triggering AI analysis #\(self.analysisCount), finalEntries=\(finalCount)")

        Task {
            defer { Task { @MainActor in self.isAnalyzing = false } }
            do {
                let result = try await aiEngine?.analyze(systemPrompt: systemPrompt, userContent: userContent)
                if let result, result.trimmingCharacters(in: .whitespacesAndNewlines) != "—" {
                    logger.info("AI analysis completed, length=\(result.count)")
                    appendChat(.assistant, result)
                }
            } catch {
                logger.error("AI analysis failed: \(error.localizedDescription)")
                appendChat(.system, "AI 分析失败: \(error.localizedDescription)")
            }
        }
    }

    func sendUserMessage() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        appendChat(.user, text)
        userInput = ""

        let customPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt")
            .flatMap { $0.isEmpty ? nil : $0 }
        let systemPrompt = customPrompt ?? Self.buildDefaultSystemPrompt(
            count: analysisCount, elapsedMin: Int(recordingDuration / 60)
        )
        let userContent = buildAnalysisUserContent() + "\n\n用户追问：\(text)"

        Task {
            do {
                let result = try await aiEngine?.analyze(systemPrompt: systemPrompt, userContent: userContent)
                if let result {
                    appendChat(.assistant, result)
                }
            } catch {
                appendChat(.system, "AI 回复失败: \(error.localizedDescription)")
            }
        }
    }

    // Step B: Import transcript
    @MainActor
    func importTranscript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.title = "选择历史转写文件"
        if let dir = sessionFileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            appendChat(.system, "无法读取文件")
            return
        }
        let imported = content.components(separatedBy: .newlines).compactMap { line -> TranscriptEntry? in
            guard line.count > 10, line.hasPrefix("[") else { return nil }
            let text = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : TranscriptEntry(timestamp: .distantPast, text: text, isFinal: true)
        }
        guard !imported.isEmpty else {
            appendChat(.system, "文件中没有找到有效的转写内容")
            return
        }
        transcriptEntries = imported + transcriptEntries
        appendChat(.system, "已导入 \(imported.count) 条历史转写（标记为「早期」内容）")
    }

    // MARK: - Private

    private func handleTranscript(text: String, isFinal: Bool) {
        logger.debug("Transcript: isFinal=\(isFinal), text=\(text.prefix(50))")
        if isFinal {
            if let lastIdx = transcriptEntries.indices.last, !transcriptEntries[lastIdx].isFinal {
                transcriptEntries[lastIdx] = TranscriptEntry(timestamp: Date(), text: text, isFinal: true)
            } else {
                transcriptEntries.append(TranscriptEntry(timestamp: Date(), text: text, isFinal: true))
            }
            // Step A: Save to session file
            appendToSessionFile(text: text, timestamp: Date())

            // Step E: Update last transcript time
            lastTranscriptTime = Date()

            // Content accumulation trigger: every 8 new final entries
            let finalCount = transcriptEntries.filter(\.isFinal).count
            if finalCount - lastAnalysisEntryCount >= 8 {
                triggerAnalysis()
            }
        } else {
            if let lastIdx = transcriptEntries.indices.last, !transcriptEntries[lastIdx].isFinal {
                transcriptEntries[lastIdx] = TranscriptEntry(timestamp: Date(), text: text, isFinal: false)
            } else {
                transcriptEntries.append(TranscriptEntry(timestamp: Date(), text: text, isFinal: false))
            }
        }
    }

    private func appendChat(_ role: ChatMessage.MessageRole, _ content: String) {
        chatMessages.append(ChatMessage(timestamp: Date(), role: role, content: content))
    }

    // MARK: - Step A: Session file

    private func createSessionFile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingAI/sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionFileURL = dir.appendingPathComponent("\(formatter.string(from: Date())).txt")
        logger.info("Session file: \(self.sessionFileURL?.path ?? "nil")")
    }

    private func appendToSessionFile(text: String, timestamp: Date) {
        guard let url = sessionFileURL else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: timestamp))] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Step D: ASR reconnect

    private func handleASRError(_ message: String) {
        let isConnectionError = message.contains("WebSocket 接收错误")
            || message.contains("ASR Bridge 错误")
            || message.contains("connection") || message.contains("Connection")

        if isConnectionError && isRecording && asrReconnectCount < maxASRReconnects {
            asrReconnectCount += 1
            appendChat(.system, "ASR 连接中断，正在重连（\(asrReconnectCount)/\(maxASRReconnects)）…")
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await reconnectASR()
            }
        } else {
            appendChat(.system, "ASR 错误: \(message)")
        }
    }

    private func reconnectASR() async {
        asrClient?.disconnect()
        asrClient = nil
        let client = ASRClient()
        client.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor [weak self] in self?.handleTranscript(text: text, isFinal: isFinal) }
        }
        client.onError = { [weak self] msg in
            Task { @MainActor [weak self] in self?.handleASRError(msg) }
        }
        client.connect(port: config.asrServerPort)
        asrClient = client
        appendChat(.system, "ASR 已重连 ✓")
        asrReconnectCount = 0
    }

    // MARK: - Step E: Smart trigger

    private func startTimers() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingDuration += 1
            }
        }
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSilenceTrigger() }
        }
    }

    private func checkSilenceTrigger() {
        guard isRecording, !isAnalyzing else { return }
        let finalCount = transcriptEntries.filter(\.isFinal).count
        let newSinceLastAnalysis = finalCount - lastAnalysisEntryCount
        guard newSinceLastAnalysis > 0 else { return }

        let silenceDuration = Date().timeIntervalSince(lastTranscriptTime)
        let timeSinceLastAnalysis = Date().timeIntervalSince(lastAnalysisTime)

        let silenceTrigger = silenceDuration > 30 && newSinceLastAnalysis >= 3
        let ceilingTrigger = timeSinceLastAnalysis > 600

        if silenceTrigger || ceilingTrigger {
            logger.info("Auto trigger: silenceTrigger=\(silenceTrigger), ceilingTrigger=\(ceilingTrigger)")
            triggerAnalysis()
        }
    }

    private func stopTimers() {
        durationTimer?.invalidate()
        silenceCheckTimer?.invalidate()
        durationTimer = nil
        silenceCheckTimer = nil
    }

    // MARK: - Step E: AI prompt builders

    static func buildDefaultSystemPrompt(count: Int, elapsedMin: Int) -> String {
        let synthNote = count > 1 && count % 5 == 0
            ? "\n\n⚡ 这一轮请做一次「全局地图」：已决定的 / 悬而未决的 / 需要跟进的行动项。"
            : ""

        return """
        你是一位旁听这场会议的智囊伙伴，思维敏锐，说话直接。
        当前是第 \(count) 次分析，会议已进行 \(elapsedMin) 分钟。

        行为原则：
        1. 先问自己「这里有什么真正有意思的？」——再开口
        2. 如果新增内容没什么值得讨论的，只输出「—」，立刻停止
        3. 有内容时，选一个你最想深挖的角度切入，不要面面俱到
        4. 观察之后，主动说出你认为值得追问或讨论的方向
        5. 格式随内容走——有时候两段话，有时候一个问题，有时候列表，自己判断
        6. 你可以有自己的立场和观点，不要重复上次说过的内容\(synthNote)
        """
    }

    private func buildAnalysisUserContent() -> String {
        let now = Date()
        let lastAIMessage = chatMessages.last(where: { $0.role == .assistant })?.content

        let tiers = transcriptEntries.filter(\.isFinal).map { entry -> String in
            let age = now.timeIntervalSince(entry.timestamp)
            let label: String
            if entry.timestamp == .distantPast {
                label = "早期"
            } else if age < 600 {
                label = "最新"
            } else if age < 1800 {
                label = "近期"
            } else {
                label = "早期"
            }
            return "[\(label)] \(entry.text)"
        }.joined(separator: "\n")

        var content = ""
        if let last = lastAIMessage {
            content += "【你上次说的】\n\(last)\n\n"
        }
        content += "【会议转写】\n\(tiers)\n\n"
        content += "请重点关注「最新」内容，「近期」和「早期」作为背景参考。"
        return content
    }
}
