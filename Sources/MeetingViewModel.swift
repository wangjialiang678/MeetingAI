import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ViewModel")

@MainActor
class MeetingViewModel: ObservableObject {
    @Published var transcriptEntries: [TranscriptEntry] = []
    @Published var insightCards: [InsightCard] = []
    @Published var isRecording = false
    @Published var isServerRunning = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var userInput = ""
    @Published var isAnalyzing = false
    @Published var aiMode: AIMode = .advisor

    // Temporary backward compat — removed when frontend task merges
    var chatMessages: [InsightCard] { insightCards }

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
    private var lastTopicKeywords: [String] = []
    private var consecutiveSilentCount = 0

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
            appendSystemMessage("ASR 服务启动失败: \(error.localizedDescription)")
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
        lastTopicKeywords = []
        consecutiveSilentCount = 0

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
            appendSystemMessage("录音启动失败: \(error.localizedDescription)")
            return
        }
        audioRecorder = recorder
        isRecording = true

        // 5. Start timers
        startTimers()

        appendSystemMessage("会议已开始，AI 将在沉默或内容积累时自动分析。点击 ⚡ 可随时手动触发分析。")
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
        saveAILog()
        let savedAILog = sessionFileURL?.deletingPathExtension().appendingPathExtension("ai.md")

        // Reset state
        analysisCount = 0
        lastAnalysisEntryCount = 0
        lastAnalysisTime = .distantPast
        lastTopicKeywords = []
        consecutiveSilentCount = 0
        sessionFileURL = nil

        var msg = "会议已结束"
        if let mp3 = savedMP3 { msg += "\n录音：\(mp3.path)" }
        if let txt = savedTxt { msg += "\n转写：\(txt.path)" }
        if let aiLog = savedAILog { msg += "\nAI记录：\(aiLog.path)" }
        appendSystemMessage(msg)
    }

    func triggerAnalysis() {
        guard isRecording, !isAnalyzing else {
            if !isRecording { appendSystemMessage("请先开始会议") }
            return
        }

        // Minimum output interval
        let minInterval: TimeInterval
        switch aiMode {
        case .observer: minInterval = .infinity
        case .advisor: minInterval = 120
        case .researcher: minInterval = 45
        }
        if Date().timeIntervalSince(lastAnalysisTime) < minInterval {
            return
        }

        let finalCount = transcriptEntries.filter(\.isFinal).count
        guard finalCount > lastAnalysisEntryCount else {
            appendSystemMessage("暂无新转写内容可分析")
            return
        }

        analysisCount += 1
        isAnalyzing = true
        lastAnalysisEntryCount = finalCount
        lastAnalysisTime = Date()

        let customPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt")
            .flatMap { $0.isEmpty ? nil : $0 }
        let systemPrompt = customPrompt ?? Self.buildDefaultSystemPrompt(
            count: analysisCount,
            elapsedMin: Int(recordingDuration / 60),
            mode: aiMode
        )
        let userContent = buildAnalysisUserContent()

        logger.info("Triggering AI analysis #\(self.analysisCount), finalEntries=\(finalCount)")

        Task {
            defer { Task { @MainActor in self.isAnalyzing = false } }
            do {
                guard let result = try await aiEngine?.analyzeStructured(systemPrompt: systemPrompt, userContent: userContent) else { return }

                // Topic change detection
                if !lastTopicKeywords.isEmpty && !result.topicKeywords.isEmpty {
                    let oldSet = Set(lastTopicKeywords)
                    let newSet = Set(result.topicKeywords)
                    let overlap = oldSet.intersection(newSet).count
                    let total = max(oldSet.count, newSet.count)
                    if total > 0 && Double(overlap) / Double(total) < 0.3 {
                        // Topic changed significantly, trigger summary
                        triggerSummary()
                    }
                }
                lastTopicKeywords = result.topicKeywords

                if result.shouldSpeak {
                    consecutiveSilentCount = 0
                    appendCard(result.kind, result.content)
                } else {
                    consecutiveSilentCount += 1
                    // Force speak after 3 consecutive silences in advisor/researcher mode
                    if aiMode != .observer && consecutiveSilentCount >= 3 {
                        consecutiveSilentCount = 0
                        appendCard(.insight, result.content)
                    }
                }
            } catch {
                logger.error("AI analysis failed: \(error.localizedDescription)")
                appendSystemMessage("AI 分析失败: \(error.localizedDescription)")
            }
        }
    }

    func sendUserMessage() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        userInput = ""

        let replyPrompt = """
        用户在会议中提问。请直接回答用户的问题，结合会议上下文给出有深度的回复。
        返回纯文本即可，不需要 JSON 格式。
        """
        let userContent = buildAnalysisUserContent() + "\n\n用户追问：\(text)"

        Task {
            do {
                let result = try await aiEngine?.analyze(systemPrompt: replyPrompt, userContent: userContent)
                if let result {
                    appendCard(.reply, result, userQuery: text)
                }
            } catch {
                appendSystemMessage("AI 回复失败: \(error.localizedDescription)")
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
            appendSystemMessage("无法读取文件")
            return
        }
        let imported = content.components(separatedBy: .newlines).compactMap { line -> TranscriptEntry? in
            guard line.count > 10, line.hasPrefix("[") else { return nil }
            let text = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : TranscriptEntry(timestamp: .distantPast, text: text, isFinal: true)
        }
        guard !imported.isEmpty else {
            appendSystemMessage("文件中没有找到有效的转写内容")
            return
        }
        transcriptEntries = imported + transcriptEntries
        appendSystemMessage("已导入 \(imported.count) 条历史转写（标记为「早期」内容）")
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

            // Content accumulation trigger based on mode
            let finalCount = transcriptEntries.filter(\.isFinal).count
            let newEntries = finalCount - lastAnalysisEntryCount
            let threshold: Int
            switch aiMode {
            case .observer: threshold = Int.max
            case .advisor: threshold = 5
            case .researcher: threshold = 3
            }
            if newEntries >= threshold {
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

    private func appendCard(_ kind: InsightCard.Kind, _ content: String, userQuery: String? = nil) {
        insightCards.append(InsightCard(content: content, kind: kind, userQuery: userQuery))
    }

    /// For system messages, use .insight kind
    private func appendSystemMessage(_ content: String) {
        appendCard(.insight, "[系统] \(content)")
    }

    private func triggerSummary() {
        guard !isAnalyzing else { return }
        let summaryPrompt = """
        请对刚才的讨论阶段做一个简短的小结，包括：已达成的共识、悬而未决的问题、建议的下一步。
        返回 JSON：{"should_speak": true, "content": "小结内容", "kind": "summary", "topic_keywords": []}
        """
        let userContent = buildAnalysisUserContent()
        Task {
            do {
                guard let result = try await aiEngine?.analyzeStructured(systemPrompt: summaryPrompt, userContent: userContent) else { return }
                if result.shouldSpeak {
                    appendCard(.summary, result.content)
                }
            } catch {
                logger.error("Summary generation failed: \(error.localizedDescription)")
            }
        }
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

    private func saveAILog() {
        guard let sessionURL = sessionFileURL else { return }
        let aiLogURL = sessionURL.deletingPathExtension().appendingPathExtension("ai.md")

        var lines: [String] = ["# AI 洞察记录\n"]

        // Pinned cards first
        let pinned = insightCards.filter(\.isPinned)
        if !pinned.isEmpty {
            lines.append("## 📌 重要标记\n")
            for card in pinned {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                lines.append("- [\(formatter.string(from: card.timestamp))] \(card.content)\n")
            }
            lines.append("")
        }

        // All cards chronologically
        lines.append("## 完整记录\n")
        for card in insightCards {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let pin = card.isPinned ? " 📌" : ""
            let prefix: String
            switch card.kind {
            case .insight: prefix = "💡"
            case .reply: prefix = "💬"
            case .summary: prefix = "📋"
            }
            if let query = card.userQuery {
                lines.append("- [\(formatter.string(from: card.timestamp))] \(prefix) 用户问: \(query)\n  \(card.content)\(pin)\n")
            } else {
                lines.append("- [\(formatter.string(from: card.timestamp))] \(prefix) \(card.content)\(pin)\n")
            }
        }

        let text = lines.joined(separator: "\n")
        try? text.write(to: aiLogURL, atomically: true, encoding: .utf8)
        logger.info("AI log saved to \(aiLogURL.path)")
    }

    // MARK: - Step D: ASR reconnect

    private func handleASRError(_ message: String) {
        let isConnectionError = message.contains("WebSocket 接收错误")
            || message.contains("ASR Bridge 错误")
            || message.contains("connection") || message.contains("Connection")

        if isConnectionError && isRecording && asrReconnectCount < maxASRReconnects {
            asrReconnectCount += 1
            appendSystemMessage("ASR 连接中断，正在重连（\(asrReconnectCount)/\(maxASRReconnects)）…")
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await reconnectASR()
            }
        } else {
            appendSystemMessage("ASR 错误: \(message)")
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
        appendSystemMessage("ASR 已重连 ✓")
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

        let silenceThreshold: TimeInterval
        let minNewEntries: Int
        switch aiMode {
        case .observer:
            return
        case .advisor:
            silenceThreshold = 60
            minNewEntries = 3
        case .researcher:
            silenceThreshold = 30
            minNewEntries = 2
        }

        let silenceTrigger = silenceDuration > silenceThreshold && newSinceLastAnalysis >= minNewEntries
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

    static func buildDefaultSystemPrompt(count: Int, elapsedMin: Int, mode: AIMode) -> String {
        let modeInstruction: String
        switch mode {
        case .observer:
            modeInstruction = "你处于观察模式。除非发现重大问题或被直接提问，否则 should_speak 设为 false。"
        case .advisor:
            modeInstruction = "你处于顾问模式。有值得分享的洞察时才发言，不要面面俱到。"
        case .researcher:
            modeInstruction = "你处于研究员模式。积极发言，主动提出问题和研究方向。"
        }

        let synthNote = count > 1 && count % 5 == 0
            ? "\n\n这一轮请做一次「阶段小结」：已决定的 / 悬而未决的 / 需要跟进的行动项。此时 kind 设为 \"summary\"。"
            : ""

        return """
        你是一位旁听这场会议的智囊伙伴，思维敏锐，说话直接。
        当前是第 \(count) 次分析，会议已进行 \(elapsedMin) 分钟。
        \(modeInstruction)

        你必须返回一个 JSON 对象（不要包裹在 markdown 代码块中），格式如下：
        {
          "should_speak": true/false,
          "content": "你想说的内容",
          "kind": "insight",
          "topic_keywords": ["关键词1", "关键词2"]
        }

        行为原则：
        1. 先判断「这里有什么真正值得说的？」— 如果没有，should_speak 设为 false
        2. 有内容时，选一个最想深挖的角度切入
        3. 观察之后，主动说出值得追问或讨论的方向
        4. kind 通常是 "insight"，阶段小结时用 "summary"
        5. topic_keywords 提取 3-5 个当前讨论的核心关键词
        6. 不要重复上次说过的内容\(synthNote)
        """
    }

    static func buildDefaultSystemPrompt(count: Int, elapsedMin: Int) -> String {
        buildDefaultSystemPrompt(count: count, elapsedMin: elapsedMin, mode: .advisor)
    }

    private func buildAnalysisUserContent() -> String {
        let now = Date()
        let lastAIMessage = insightCards.last?.content

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
