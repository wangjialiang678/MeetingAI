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
    @Published var aiMode: AIMode = .advisor {
        didSet {
            guard oldValue != aiMode else { return }
            logger.info("AI mode changed: \(oldValue.rawValue) -> \(self.aiMode.rawValue)")
            appendEvent("ai_mode_changed", fields: ["from": oldValue.rawValue, "to": aiMode.rawValue])
        }
    }
    @Published var analysisActivityText: String?
    @Published var lastAnalysisStatusText: String = "后端：Hybrid"
    @Published var speakerBackfillSegments: [DiarizedTranscriptSegment] = []

    private var audioRecorder: AudioRecorder?
    private var asrClient: ASRClient?
    private var asrClientGeneration = 0
    private var aiEngine: AIEngine?
    private var serverManager: ASRServerManager?

    // Timers
    private var durationTimer: Timer?
    private var silenceCheckTimer: Timer?

    private let config: AppConfig

    // Step A: Session file saving
    private var sessionFileURL: URL?
    private var sessionRecordingURL: URL?
    private var sessionEventLogURL: URL?
    private var sessionTranscriptMarkdownURL: URL?
    private var sessionChunksLogURL: URL?
    private var diarizationChunker: DiarizationAudioChunker?
    private var diarizationPipeline: DiarizationPipeline?
    private var diarizationLoggedChunkIndices: Set<Int> = []
    private var diarizationProcessingChunkIndices: Set<Int> = []
    private var diarizationProcessingTasks: [Task<Void, Never>] = []
    private var diarizationSessionGate = DiarizationSessionGate()
    private var fixtureTranscriptTask: Task<Void, Never>?

    // Step D: ASR reconnect
    private var asrReconnectCount = 0
    private let maxASRReconnects = 3
    private var asrReconnectTask: Task<Void, Never>?
    private let initialASRReconnectBackoffSeconds: TimeInterval = 1
    private let maxASRReconnectBackoffSeconds: TimeInterval = 16
    private var asrReconnectBackoffSeconds: TimeInterval = 1
    private var asrReconnectGaveUp = false

    // Step E: Smart trigger state — text-length based (works with partial ASR)
    private var lastAnalysisTextLength = 0
    private var lastTranscriptTime = Date.distantPast
    private var lastAnalysisTime = Date.distantPast
    private var analysisCount = 0
    private var lastTopicKeywords: [String] = []
    private var consecutiveSilentCount = 0
    private var didLogAutoSkipSinceLastAnalysis = false
    private var lastWatchdogRotateAt: Date?
    private(set) var meetingStartDate: Date?

    /// 说话人分离已覆盖到的绝对时间；早于它的实时 final 条目在 UI 中被说话人段落替代
    var speakerCoverageCutoffDate: Date? {
        guard let meetingStartDate,
              let maxEnd = speakerBackfillSegments.map(\.endMilliseconds).max() else { return nil }
        return meetingStartDate.addingTimeInterval(TimeInterval(maxEnd) / 1_000)
    }

    init() {
        config = AppConfig.load()
        logger.info("Config loaded: ASR port=\(self.config.asrServerPort), AI model=\(self.config.aiModel)")
        logger.info("Credentials loaded: dashscope=\(!self.config.dashscopeAPIKey.isEmpty), ai=\(!self.config.aiAPIKey.isEmpty), fixture=\(self.config.uiFixtureMode)")
        lastAnalysisStatusText = "后端：\(currentAnalysisBackend().displayName)"
    }

    func startMeeting() async {
        logger.info("Starting meeting with backend=\(self.currentAnalysisBackend().rawValue), fixture=\(self.config.uiFixtureMode)")

        // Reset state
        _ = diarizationSessionGate.beginNewSession()
        cancelDiarizationProcessingTasks(reason: "new_meeting_started")
        resetASRReconnectState(reason: "meeting_started", logEvent: false)
        analysisCount = 0
        lastAnalysisTextLength = 0
        lastAnalysisTime = .distantPast
        lastTranscriptTime = .distantPast
        lastTopicKeywords = []
        consecutiveSilentCount = 0
        didLogAutoSkipSinceLastAnalysis = false
        meetingStartDate = Date()
        lastWatchdogRotateAt = nil
        speakerBackfillSegments = []
        diarizationLoggedChunkIndices.removeAll()
        diarizationProcessingChunkIndices.removeAll()
        diarizationProcessingTasks.removeAll()
        diarizationPipeline = nil

        createSessionFiles()
        sessionRecordingURL = sessionFileURL?.deletingPathExtension().appendingPathExtension("mp3")
        appendEvent("meeting_start_requested", fields: meetingConfigEventFields())

        if config.uiFixtureMode {
            startFixtureMeeting()
            return
        }

        // 1. Start ASR server
        serverManager = ASRServerManager(port: config.asrServerPort, apiKey: config.dashscopeAPIKey)
        do {
            appendEvent("asr_server_starting", fields: ["port": config.asrServerPort])
            try await serverManager!.start()
            isServerRunning = true
            appendEvent("asr_server_started", fields: ["port": config.asrServerPort])
        } catch {
            logger.error("Failed to start ASR server: \(error.localizedDescription)")
            appendEvent("asr_server_start_failed", fields: ["error": error.localizedDescription])
            appendSystemMessage("ASR 服务启动失败: \(error.localizedDescription)")
            return
        }

        // 2. Setup AI engine
        aiEngine = makeAIEngine(fixtureMode: false)

        // 3. Setup ASR client
        let client = ASRClient()
        asrClientGeneration += 1
        configureASRClient(client, generation: asrClientGeneration)
        client.connect(port: config.asrServerPort)
        asrClient = client

        // 4. Start recording
        diarizationPipeline = makeDiarizationPipelineIfConfigured()
        let chunker = makeDiarizationChunkerIfEnabled()
        diarizationChunker = chunker

        let recorder = AudioRecorder()
        recorder.onAudioData = { [weak self] data in
            self?.asrClient?.sendAudio(data)
            chunker?.appendPCM16(data)
        }
        do {
            try recorder.start(recordingURL: sessionRecordingURL)
        } catch {
            logger.error("Failed to start recorder: \(error.localizedDescription)")
            appendEvent("recorder_start_failed", fields: ["error": error.localizedDescription])
            appendSystemMessage("录音启动失败: \(error.localizedDescription)")
            return
        }
        audioRecorder = recorder
        isRecording = true
        appendEvent("recorder_started", fields: ["recordingPath": recorder.recordingURL?.path ?? sessionRecordingURL?.path ?? "nil"])

        // 5. Start timers
        startTimers()

        appendEvent("meeting_started", fields: ["fixture": config.uiFixtureMode])
        appendSystemMessage("会议已开始，AI 将在沉默或内容积累时自动分析。点击 ⚡ 可随时手动触发分析。")
    }

    func stopMeeting() {
        logger.info("Stopping meeting...")
        let savedDurationSeconds = Int(recordingDuration)
        let asrDrainSeconds: TimeInterval = 1.0
        appendEvent("meeting_stop_requested", fields: [
            "durationSeconds": savedDurationSeconds,
            "transcriptEntries": transcriptEntries.count,
            "insightCards": insightCards.count
        ])
        cancelPendingASRReconnect(reason: "meeting_stopped")
        stopTimers()

        fixtureTranscriptTask?.cancel()
        fixtureTranscriptTask = nil

        let savedRecording = audioRecorder?.recordingURL ?? sessionRecordingURL
        audioRecorder?.stop()
        audioRecorder = nil
        let chunkFinalization = finalizeDiarizationChunks()

        let clientToDisconnect = asrClient
        asrClient = nil
        isRecording = false
        recordingDuration = 0

        if let clientToDisconnect {
            appendEvent("asr_disconnect_waiting", fields: ["graceSeconds": asrDrainSeconds])
            clientToDisconnect.disconnect(gracePeriod: asrDrainSeconds) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finalizeStoppedMeeting(
                        savedRecording: savedRecording,
                        savedDurationSeconds: savedDurationSeconds,
                        savedChunksLog: chunkFinalization.logURL,
                        savedChunksDirectory: chunkFinalization.directoryURL,
                        savedChunkCount: chunkFinalization.count
                    )
                }
            }
        } else {
            finalizeStoppedMeeting(
                savedRecording: savedRecording,
                savedDurationSeconds: savedDurationSeconds,
                savedChunksLog: chunkFinalization.logURL,
                savedChunksDirectory: chunkFinalization.directoryURL,
                savedChunkCount: chunkFinalization.count
            )
        }
    }

    private func finalizeStoppedMeeting(
        savedRecording: URL?,
        savedDurationSeconds: Int,
        savedChunksLog: URL?,
        savedChunksDirectory: URL?,
        savedChunkCount: Int
    ) {
        asrClientGeneration += 1
        serverManager?.stop()
        serverManager = nil
        isServerRunning = false

        let savedTxt = sessionFileURL
        if let savedTxt {
            let completeText = TranscriptStore.completeTranscriptText(entries: transcriptEntries)
            do {
                try completeText.write(to: savedTxt, atomically: true, encoding: .utf8)
                appendEvent("transcript_txt_finalized", fields: [
                    "entries": transcriptEntries.count,
                    "chars": completeText.count
                ])
            } catch {
                logger.error("Failed to finalize complete txt: \(error.localizedDescription)")
                appendEvent("transcript_txt_append_failed", fields: ["stage": "finalize", "error": error.localizedDescription])
            }
        }
        writeTranscriptMarkdownSnapshot()
        let savedTranscriptMarkdown = sessionTranscriptMarkdownURL
        appendEvent("transcript_markdown_saved", fields: [
            "path": savedTranscriptMarkdown?.path ?? "nil",
            "entries": transcriptEntries.count,
            "finalEntries": transcriptEntries.filter(\.isFinal).count
        ])
        saveAILog()
        let savedAILog = sessionFileURL?.deletingPathExtension().appendingPathExtension("ai.md")
        let savedEventLog = sessionEventLogURL
        appendEvent("meeting_stopped", fields: [
            "durationSeconds": savedDurationSeconds,
            "recordingPath": savedRecording?.path ?? "nil",
            "mp3Path": savedRecording?.path ?? "nil",
            "txtPath": savedTxt?.path ?? "nil",
            "transcriptMarkdownPath": savedTranscriptMarkdown?.path ?? "nil",
            "aiLogPath": savedAILog?.path ?? "nil",
            "eventLogPath": savedEventLog?.path ?? "nil",
            "chunksLogPath": savedChunksLog?.path ?? "nil",
            "chunksDirectoryPath": savedChunksDirectory?.path ?? "nil",
            "diarizationChunkCount": savedChunkCount
        ])

        // Reset state
        analysisCount = 0
        lastAnalysisTextLength = 0
        lastAnalysisTime = .distantPast
        lastTopicKeywords = []
        consecutiveSilentCount = 0
        didLogAutoSkipSinceLastAnalysis = false
        sessionFileURL = nil
        sessionRecordingURL = nil
        sessionEventLogURL = nil
        sessionTranscriptMarkdownURL = nil
        sessionChunksLogURL = nil
        diarizationPipeline = nil

        var msg = "会议已结束"
        if let recording = savedRecording { msg += "\n录音：\(recording.path)" }
        if let txt = savedTxt { msg += "\n转写：\(txt.path)" }
        if let transcriptMarkdown = savedTranscriptMarkdown { msg += "\n转写Markdown：\(transcriptMarkdown.path)" }
        if let aiLog = savedAILog { msg += "\nAI记录：\(aiLog.path)" }
        if let eventLog = savedEventLog { msg += "\n事件日志：\(eventLog.path)" }
        if let chunksLog = savedChunksLog, savedChunkCount > 0 { msg += "\n分片日志：\(chunksLog.path)" }
        logger.info("Meeting stopped. savedRecording=\(savedRecording?.path ?? "nil"), savedTxt=\(savedTxt?.path ?? "nil"), savedTranscriptMarkdown=\(savedTranscriptMarkdown?.path ?? "nil"), savedAILog=\(savedAILog?.path ?? "nil"), savedEventLog=\(savedEventLog?.path ?? "nil")")
        appendSystemMessage(msg)
    }

    func triggerAnalysis() {
        triggerAnalysis(source: "manual")
    }

    private func triggerAnalysis(source: String) {
        guard isRecording, !isAnalyzing else {
            if !isRecording { appendSystemMessage("请先开始会议") }
            if isRecording && source == "manual" {
                appendSystemMessage("AI 正在分析中，请稍后再试。")
            }
            logSkipEventIfNeeded(source: source, fields: [
                "source": source,
                "reason": isRecording ? "already_analyzing" : "not_recording"
            ])
            return
        }

        // Minimum output interval（按需发言：顾问模式 2026-07-18 由 120s 调至 180s）
        let minInterval: TimeInterval
        switch aiMode {
        case .observer: minInterval = .infinity
        case .advisor: minInterval = 180
        case .researcher: minInterval = 45
        }
        let elapsedSinceLastAnalysis = Date().timeIntervalSince(lastAnalysisTime)
        if elapsedSinceLastAnalysis < minInterval {
            let minIntervalText = minInterval.isFinite ? "\(Int(minInterval))" : "infinity"
            let remainingSeconds = minInterval.isFinite ? max(1, Int(ceil(minInterval - elapsedSinceLastAnalysis))) : 0
            logger.debug("Analysis skipped: min interval not met (mode=\(self.aiMode.rawValue), interval=\(Int(elapsedSinceLastAnalysis))s/\(minIntervalText)s)")
            logSkipEventIfNeeded(source: source, fields: [
                "source": source,
                "reason": "min_interval",
                "mode": aiMode.rawValue,
                "elapsedSeconds": Int(elapsedSinceLastAnalysis),
                "minIntervalSeconds": minIntervalText,
                "remainingSeconds": remainingSeconds
            ])
            if source == "manual" {
                if minInterval.isFinite {
                    appendSystemMessage("距上次分析不足 \(Int(minInterval)) 秒，请 \(remainingSeconds) 秒后再试。")
                } else {
                    appendSystemMessage("当前模式不会主动分析，请切换到顾问或研究员模式后再试。")
                }
            }
            return
        }

        let currentTextLength = totalTranscriptLength()
        guard currentTextLength > lastAnalysisTextLength else {
            logSkipEventIfNeeded(source: source, fields: [
                "source": source,
                "reason": "no_new_transcript",
                "totalChars": currentTextLength
            ])
            if source == "manual" {
                appendSystemMessage("暂无新转写内容可分析")
            }
            return
        }

        analysisCount += 1
        didLogAutoSkipSinceLastAnalysis = false
        isAnalyzing = true
        let newChars = currentTextLength - lastAnalysisTextLength
        lastAnalysisTextLength = currentTextLength
        lastAnalysisTime = Date()

        let customPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt")
            .flatMap { $0.isEmpty ? nil : $0 }
        let intent: AnalysisIntent = .insight
        let plannedBackend = currentAnalysisBackend().preferredBackend(for: intent)
        let systemPrompt = customPrompt ?? Self.buildDefaultSystemPrompt(
            count: analysisCount,
            elapsedMin: Int(recordingDuration / 60),
            mode: aiMode
        )
        let userContent = buildAnalysisUserContent()

        aiEngine = makeAIEngine(fixtureMode: config.uiFixtureMode)
        analysisActivityText = "分析中 · \(plannedBackend.displayName)"
        logger.info("Triggering AI analysis #\(self.analysisCount), intent=\(intent.rawValue), backend=\(plannedBackend.rawValue), newChars=\(newChars), totalChars=\(currentTextLength)")
        appendEvent("analysis_triggered", fields: [
            "source": source,
            "count": analysisCount,
            "intent": intent.rawValue,
            "plannedBackend": plannedBackend.rawValue,
            "newChars": newChars,
            "totalChars": currentTextLength
        ])

        Task {
            defer {
                Task { @MainActor in
                    self.isAnalyzing = false
                    self.analysisActivityText = nil
                }
            }
            do {
                guard let result = try await aiEngine?.analyzeStructured(
                    systemPrompt: systemPrompt,
                    userContent: userContent,
                    intent: intent
                ) else { return }

                // Topic change detection
                if !lastTopicKeywords.isEmpty && !result.topicKeywords.isEmpty {
                    let oldSet = Set(lastTopicKeywords)
                    let newSet = Set(result.topicKeywords)
                    let overlap = oldSet.intersection(newSet).count
                    let total = max(oldSet.count, newSet.count)
                    let overlapRatio = total > 0 ? Double(overlap) / Double(total) : 1.0
                    logger.debug("Topic change: old=\(self.lastTopicKeywords) new=\(result.topicKeywords) overlap=\(String(format: "%.0f%%", overlapRatio * 100))")
                    if total > 0 && overlapRatio < 0.3 {
                        logger.info("Topic changed significantly, triggering summary")
                        triggerSummary()
                    }
                }
                lastTopicKeywords = result.topicKeywords

                if result.shouldSpeak {
                    consecutiveSilentCount = 0
                    logger.info("AI speaks: kind=\(result.kind.rawValue), backend=\(result.execution.usedBackend.rawValue), fallback=\(result.execution.fallbackOccurred), keywords=\(result.topicKeywords.joined(separator: ","))")
                    lastAnalysisStatusText = result.execution.statusText
                    appendEvent("analysis_completed", fields: [
                        "source": source,
                        "result": "spoken",
                        "kind": result.kind.rawValue,
                        "usedBackend": result.execution.usedBackend.rawValue,
                        "fallback": result.execution.fallbackOccurred,
                        "durationSeconds": result.execution.durationSeconds
                    ])
                    if result.kind == .insight, let similarity = duplicateInsightSimilarity(result.content) {
                        logger.info("Insight discarded as near-duplicate, similarity=\(similarity, format: .fixed(precision: 2)), source=\(source)")
                        appendEvent("analysis_discarded_duplicate", fields: [
                            "source": source,
                            "similarity": (similarity * 100).rounded() / 100,
                            "usedBackend": result.execution.usedBackend.rawValue
                        ])
                        if source == "manual" {
                            appendSystemMessage("本次分析结果与最近洞察基本重复，已跳过展示。", execution: result.execution)
                        }
                    } else {
                        appendCard(result.kind, result.content, execution: result.execution)
                    }
                    if result.execution.fallbackOccurred {
                        appendSystemMessage("Codex CLI 调用失败，已自动回退到 HTTP。", execution: result.execution)
                    }
                } else {
                    consecutiveSilentCount += 1
                    logger.info("AI silent (count=\(self.consecutiveSilentCount)), backend=\(result.execution.usedBackend.rawValue), fallback=\(result.execution.fallbackOccurred), keywords=\(result.topicKeywords.joined(separator: ","))")
                    lastAnalysisStatusText = result.execution.statusText
                    appendEvent("analysis_completed", fields: [
                        "source": source,
                        "result": "silent",
                        "usedBackend": result.execution.usedBackend.rawValue,
                        "fallback": result.execution.fallbackOccurred,
                        "durationSeconds": result.execution.durationSeconds,
                        "consecutiveSilentCount": consecutiveSilentCount
                    ])
                    // Force speak after 3 consecutive silences in advisor/researcher mode
                    // 按需发言：连续沉默兜底从 3 次放宽到 5 次（2026-07-18 用户决策）
                    if aiMode != .observer && consecutiveSilentCount >= 5 {
                        if let similarity = duplicateInsightSimilarity(result.content) {
                            logger.info("Force-speak insight discarded as near-duplicate, similarity=\(similarity, format: .fixed(precision: 2))")
                            appendEvent("analysis_discarded_duplicate", fields: [
                                "source": source,
                                "similarity": (similarity * 100).rounded() / 100,
                                "usedBackend": result.execution.usedBackend.rawValue,
                                "forced": true
                            ])
                        } else {
                            logger.info("Force speak after \(self.consecutiveSilentCount) consecutive silences")
                            consecutiveSilentCount = 0
                            appendCard(.insight, result.content, execution: result.execution)
                        }
                    }
                }
            } catch {
                logger.error("AI analysis failed: \(error.localizedDescription)")
                lastAnalysisStatusText = failureStatusText(stage: "分析", backend: plannedBackend, error: error)
                appendEvent("analysis_failed", fields: [
                    "source": source,
                    "plannedBackend": plannedBackend.rawValue,
                    "error": error.localizedDescription
                ])
                appendSystemMessage("AI 分析失败（\(plannedBackend.displayName)）: \(userFacingErrorMessage(error))")
            }
        }
    }

    func sendUserMessage() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        logger.info("User question: \(text.prefix(80))")
        userInput = ""

        let replyPrompt = """
        用户在会议中提问。请直接回答用户的问题，结合会议上下文给出有深度的回复。
        返回纯文本即可，不需要 JSON 格式。
        """
        let userContent = buildAnalysisUserContent() + "\n\n用户追问：\(text)"
        let intent: AnalysisIntent = .reply
        let plannedBackend = currentAnalysisBackend().preferredBackend(for: intent)
        aiEngine = makeAIEngine(fixtureMode: config.uiFixtureMode)
        analysisActivityText = "分析中 · \(plannedBackend.displayName)"
        logger.info("Triggering AI reply, intent=\(intent.rawValue), backend=\(plannedBackend.rawValue)")
        appendEvent("analysis_triggered", fields: [
            "source": "user_message",
            "intent": intent.rawValue,
            "plannedBackend": plannedBackend.rawValue,
            "queryChars": text.count
        ])

        Task {
            defer { Task { @MainActor in self.analysisActivityText = nil } }
            do {
                let result = try await aiEngine?.analyze(systemPrompt: replyPrompt, userContent: userContent, intent: intent)
                if let result {
                    lastAnalysisStatusText = result.execution.statusText
                    appendEvent("analysis_completed", fields: [
                        "source": "user_message",
                        "result": "reply",
                        "usedBackend": result.execution.usedBackend.rawValue,
                        "fallback": result.execution.fallbackOccurred,
                        "durationSeconds": result.execution.durationSeconds
                    ])
                    appendCard(.reply, result.content, userQuery: text, execution: result.execution)
                    if result.execution.fallbackOccurred {
                        appendSystemMessage("Codex CLI 回复失败，已自动回退到 HTTP。", execution: result.execution)
                    }
                }
            } catch {
                logger.error("AI reply failed: \(error.localizedDescription)")
                lastAnalysisStatusText = failureStatusText(stage: "追问", backend: plannedBackend, error: error)
                appendEvent("analysis_failed", fields: [
                    "source": "user_message",
                    "plannedBackend": plannedBackend.rawValue,
                    "error": error.localizedDescription
                ])
                appendSystemMessage("AI 回复失败（\(plannedBackend.displayName)）: \(userFacingErrorMessage(error))")
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
            logger.error("Failed to read imported transcript: \(url.path)")
            appendSystemMessage("无法读取文件")
            return
        }
        let imported = content.components(separatedBy: .newlines).compactMap { line -> TranscriptEntry? in
            guard line.count > 10, line.hasPrefix("[") else { return nil }
            let text = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : TranscriptEntry(timestamp: .distantPast, text: text, isFinal: true)
        }
        guard !imported.isEmpty else {
            logger.warning("Imported transcript had no valid entries: \(url.path)")
            appendSystemMessage("文件中没有找到有效的转写内容")
            return
        }
        transcriptEntries = imported + transcriptEntries
        writeTranscriptMarkdownSnapshot()
        logger.info("Imported transcript entries: count=\(imported.count), path=\(url.path)")
        appendEvent("transcript_imported", fields: ["count": imported.count, "path": url.path])
        appendSystemMessage("已导入 \(imported.count) 条历史转写（标记为「早期」内容）")
    }

    // MARK: - Private

    private func handleTranscript(text: String, isFinal: Bool) {
        logger.debug("Transcript: isFinal=\(isFinal), text=\(text.prefix(50))")
        let timestamp = Date()

        // Update or append entry
        if isFinal {
            if let lastIdx = transcriptEntries.indices.last, !transcriptEntries[lastIdx].isFinal {
                let firstSeen = transcriptEntries[lastIdx].firstTimestamp
                transcriptEntries[lastIdx] = TranscriptEntry(timestamp: timestamp, text: text, isFinal: true, firstTimestamp: firstSeen)
            } else {
                transcriptEntries.append(TranscriptEntry(timestamp: timestamp, text: text, isFinal: true))
            }
            // Save final text to session file
            appendToSessionFile(text: text, timestamp: timestamp)
        } else {
            if let lastIdx = transcriptEntries.indices.last, !transcriptEntries[lastIdx].isFinal {
                let firstSeen = transcriptEntries[lastIdx].firstTimestamp
                transcriptEntries[lastIdx] = TranscriptEntry(timestamp: timestamp, text: text, isFinal: false, firstTimestamp: firstSeen)
            } else {
                transcriptEntries.append(TranscriptEntry(timestamp: timestamp, text: text, isFinal: false))
            }
        }
        writeTranscriptMarkdownSnapshot()
        appendEvent(isFinal ? "transcript_final" : "transcript_partial", fields: [
            "chars": text.count,
            "entries": transcriptEntries.count,
            "finalEntries": transcriptEntries.filter(\.isFinal).count
        ])

        // Update last transcript time for both partial and final
        lastTranscriptTime = timestamp

        // Text accumulation trigger (works with partial — no need to wait for final)
        let currentLength = totalTranscriptLength()
        let newChars = currentLength - lastAnalysisTextLength
        let charThreshold: Int
        switch aiMode {
        case .observer: charThreshold = Int.max
        case .advisor: charThreshold = 200
        case .researcher: charThreshold = 100
        }
        if newChars >= charThreshold {
            triggerAnalysis(source: "text_growth")
        }
    }

    private func appendCard(
        _ kind: InsightCard.Kind,
        _ content: String,
        userQuery: String? = nil,
        execution: AnalysisExecutionMetadata? = nil
    ) {
        insightCards.append(InsightCard(content: content, kind: kind, userQuery: userQuery, execution: execution))
        logger.debug("Card appended: kind=\(kind.rawValue), cards=\(self.insightCards.count), backend=\(execution?.usedBackend.rawValue ?? "none"), fallback=\(execution?.fallbackOccurred ?? false)")
        appendEvent("ai_card_appended", fields: [
            "kind": kind.rawValue,
            "cards": insightCards.count,
            "contentChars": content.count,
            "hasUserQuery": userQuery != nil,
            "usedBackend": execution?.usedBackend.rawValue ?? "none",
            "fallback": execution?.fallbackOccurred ?? false
        ])
    }

    private func appendSystemMessage(_ content: String, execution: AnalysisExecutionMetadata? = nil) {
        appendCard(.system, content, execution: execution)
    }

    /// 降噪：自动触发的 skip 事件在两次分析之间只记录一次（手动触发始终记录）。
    /// 此前每条 partial 到达都会写一条 min_interval skip，31 分钟真实会议产生了 4623 条噪声。
    private func logSkipEventIfNeeded(source: String, fields: [String: Any]) {
        if source != "manual" {
            guard !didLogAutoSkipSinceLastAnalysis else { return }
            didLogAutoSkipSinceLastAnalysis = true
        }
        appendEvent("analysis_skipped", fields: fields)
    }

    private func duplicateInsightSimilarity(_ content: String) -> Double? {
        let recentInsights = insightCards
            .filter { $0.kind == .insight }
            .suffix(InsightDeduplicator.defaultWindow)
            .map(\.content)
        return InsightDeduplicator.duplicateSimilarity(candidate: content, recentInsights: Array(recentInsights))
    }

    private func triggerSummary() {
        guard !isAnalyzing else { return }
        let summaryPrompt = """
        请对刚才的讨论阶段做一个简短的小结，包括：已达成的共识、悬而未决的问题、建议的下一步。
        返回 JSON：{"should_speak": true, "content": "小结内容", "kind": "summary", "topic_keywords": []}
        """
        let userContent = buildAnalysisUserContent()
        let intent: AnalysisIntent = .summary
        let plannedBackend = currentAnalysisBackend().preferredBackend(for: intent)
        aiEngine = makeAIEngine(fixtureMode: config.uiFixtureMode)
        analysisActivityText = "分析中 · \(plannedBackend.displayName)"
        logger.info("Triggering AI summary, intent=\(intent.rawValue), backend=\(plannedBackend.rawValue)")
        appendEvent("analysis_triggered", fields: [
            "source": "topic_change",
            "intent": intent.rawValue,
            "plannedBackend": plannedBackend.rawValue
        ])
        Task {
            defer { Task { @MainActor in self.analysisActivityText = nil } }
            do {
                guard let result = try await aiEngine?.analyzeStructured(
                    systemPrompt: summaryPrompt,
                    userContent: userContent,
                    intent: intent
                ) else { return }
                if result.shouldSpeak {
                    lastAnalysisStatusText = result.execution.statusText
                    appendEvent("analysis_completed", fields: [
                        "source": "topic_change",
                        "result": "summary",
                        "usedBackend": result.execution.usedBackend.rawValue,
                        "fallback": result.execution.fallbackOccurred,
                        "durationSeconds": result.execution.durationSeconds
                    ])
                    appendCard(.summary, result.content, execution: result.execution)
                    if result.execution.fallbackOccurred {
                        appendSystemMessage("Codex CLI 小结失败，已自动回退到 HTTP。", execution: result.execution)
                    }
                }
            } catch {
                logger.error("Summary generation failed: \(error.localizedDescription)")
                lastAnalysisStatusText = failureStatusText(stage: "小结", backend: plannedBackend, error: error)
                appendEvent("analysis_failed", fields: [
                    "source": "topic_change",
                    "plannedBackend": plannedBackend.rawValue,
                    "error": error.localizedDescription
                ])
                appendSystemMessage("AI 小结失败（\(plannedBackend.displayName)）: \(userFacingErrorMessage(error))")
            }
        }
    }

    // MARK: - Step A: Session file

    private func startFixtureMeeting() {
        logger.info("Starting fixture meeting mode")
        aiEngine = makeAIEngine(fixtureMode: true)
        isServerRunning = true
        isRecording = true
        recordingDuration = 0
        startTimers()

        if let recordingURL = sessionRecordingURL {
            do {
                try Data().write(to: recordingURL, options: .atomic)
                logger.info("Fixture MP3 placeholder created at \(recordingURL.path)")
                appendEvent("fixture_mp3_placeholder_created", fields: ["path": recordingURL.path])
            } catch {
                logger.error("Failed to create fixture MP3 placeholder: \(error.localizedDescription)")
                appendEvent("fixture_mp3_placeholder_failed", fields: ["error": error.localizedDescription])
            }
        }

        fixtureTranscriptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for line in Self.fixtureTranscriptLines {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard self.isRecording else { return }
                self.handleTranscript(text: line, isFinal: true)
            }
        }

        appendEvent("meeting_started", fields: ["fixture": config.uiFixtureMode])
        appendSystemMessage("会议已开始，AI 将在沉默或内容积累时自动分析。点击 ⚡ 可随时手动触发分析。")
    }

    private func createSessionFiles() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let dir = config.sessionsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create sessions directory: \(dir.path), error=\(error.localizedDescription)")
        }
        let baseURL = dir.appendingPathComponent(formatter.string(from: Date()))
        sessionFileURL = baseURL.appendingPathExtension("txt")
        sessionEventLogURL = baseURL.appendingPathExtension("events.log")
        sessionTranscriptMarkdownURL = baseURL.appendingPathExtension("transcript.md")
        sessionChunksLogURL = baseURL.appendingPathExtension("chunks.jsonl")
        writeTranscriptMarkdownSnapshot()
        logger.info("Session files: txt=\(self.sessionFileURL?.path ?? "nil"), events=\(self.sessionEventLogURL?.path ?? "nil"), transcriptMarkdown=\(self.sessionTranscriptMarkdownURL?.path ?? "nil")")
        appendEvent("session_files_created", fields: [
            "txtPath": sessionFileURL?.path ?? "nil",
            "eventLogPath": sessionEventLogURL?.path ?? "nil",
            "transcriptMarkdownPath": sessionTranscriptMarkdownURL?.path ?? "nil",
            "chunksLogPath": sessionChunksLogURL?.path ?? "nil"
        ])
    }

    private func makeDiarizationChunkerIfEnabled() -> DiarizationAudioChunker? {
        guard config.segmentedDiarizationEnabled, let sessionFileURL else {
            appendEvent("diarization_chunker_disabled", fields: [
                "enabled": config.segmentedDiarizationEnabled
            ])
            return nil
        }
        let chunkDurationMilliseconds = max(1, Int(config.diarizationChunkDurationSeconds * 1_000))
        let chunker = DiarizationAudioChunker(
            sessionFileURL: sessionFileURL,
            chunkDurationMilliseconds: chunkDurationMilliseconds
        )
        chunker.onChunkSealed = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.handleDiarizationChunkSealed(chunk)
            }
        }
        appendEvent("diarization_chunker_started", fields: [
            "chunkDurationSeconds": config.diarizationChunkDurationSeconds,
            "chunksLogPath": chunker.chunksLogURL.path,
            "chunksDirectoryPath": chunker.chunksDirectoryURL.path,
            "uploadProviderConfigured": diarizationPipeline != nil
        ])
        return chunker
    }

    private func makeDiarizationPipelineIfConfigured() -> DiarizationPipeline? {
        guard config.segmentedDiarizationEnabled else { return nil }
        guard config.diarizationProvider == DiarizationProvider.dashscopeFunASR.rawValue else {
            appendEvent("diarization_pipeline_disabled", fields: [
                "reason": "provider_not_dashscope_fun_asr",
                "provider": config.diarizationProvider
            ])
            return nil
        }
        guard config.diarizationUploadStorage == DiarizationUploadStorage.oss.rawValue else {
            appendEvent("diarization_pipeline_disabled", fields: [
                "reason": "upload_storage_not_oss",
                "uploadStorage": config.diarizationUploadStorage
            ])
            return nil
        }
        guard let sessionFileURL, let sessionEventLogURL else { return nil }
        guard let baseURL = URL(string: config.diarizationFunASRBaseURL) else {
            appendEvent("diarization_pipeline_disabled", fields: ["reason": "invalid_fun_asr_base_url"])
            return nil
        }
        guard !config.dashscopeAPIKey.isEmpty else {
            appendEvent("diarization_pipeline_disabled", fields: ["reason": "dashscope_api_key_not_loaded"])
            return nil
        }
        let ossConfig = DiarizationOSSUploadConfiguration(
            region: config.diarizationUploadRegion,
            endpoint: config.diarizationUploadEndpoint,
            bucket: config.diarizationUploadBucket,
            objectPrefix: config.diarizationObjectPrefix,
            accessKeyID: config.ossAccessKeyID,
            accessKeySecret: config.ossAccessKeySecret,
            sessionToken: config.ossSessionToken,
            presignTTLSeconds: config.diarizationPresignTTLSeconds
        )
        guard ossConfig.isReady else {
            appendEvent("diarization_pipeline_disabled", fields: [
                "reason": ossConfig.missingConfigurationReason ?? "oss_not_configured",
                "uploadStorage": config.diarizationUploadStorage,
                "uploadRegion": config.diarizationUploadRegion,
                "uploadEndpointHost": ossConfig.normalizedEndpoint,
                "uploadBucketConfigured": !config.diarizationUploadBucket.isEmpty,
                "ossCredentialLoaded": !config.ossAccessKeyID.isEmpty && !config.ossAccessKeySecret.isEmpty
            ])
            return nil
        }
        do {
            let uploader = try DiarizationOSSUploader(
                config: ossConfig,
                sessionStem: sessionFileURL.deletingPathExtension().lastPathComponent
            )
            let provider = DashScopeFunASRProvider(
                apiKey: config.dashscopeAPIKey,
                baseURL: baseURL,
                pollIntervalSeconds: config.diarizationPollIntervalSeconds,
                timeoutSeconds: config.diarizationPollTimeoutSeconds
            )
            appendEvent("diarization_pipeline_started", fields: [
                "provider": config.diarizationProvider,
                "uploadStorage": config.diarizationUploadStorage,
                "uploadRegion": config.diarizationUploadRegion,
                "uploadEndpointHost": ossConfig.normalizedEndpoint,
                "uploadBucket": config.diarizationUploadBucket,
                "objectPrefix": ossConfig.normalizedObjectPrefix,
                "presignTTLSeconds": ossConfig.clampedPresignTTLSeconds,
                "pollIntervalSeconds": config.diarizationPollIntervalSeconds,
                "pollTimeoutSeconds": config.diarizationPollTimeoutSeconds,
                "speakerCountConfigured": config.diarizationSpeakerCount as Any
            ])
            let sessionGeneration = diarizationSessionGate.currentGeneration
            return DiarizationPipeline(
                sessionFileURL: sessionFileURL,
                eventLogURL: sessionEventLogURL,
                language: config.asrLanguage,
                uploader: uploader,
                provider: provider,
                speakerCount: config.diarizationSpeakerCount,
                onSegmentsUpdated: { [weak self] segments in
                    guard let self, self.diarizationSessionGate.accepts(sessionGeneration) else { return }
                    self.speakerBackfillSegments = segments
                    self.writeTranscriptMarkdownSnapshot()
                },
                sentenceRefiner: { [weak self] chunk, sentences in
                    guard let self, self.diarizationSessionGate.accepts(sessionGeneration) else {
                        return (sentences, 0)
                    }
                    return await self.refineDiarizedSentences(chunk: chunk, sentences: sentences)
                }
            )
        } catch {
            appendEvent("diarization_pipeline_disabled", fields: [
                "reason": DiarizationLogSanitizer.redactSensitiveText(error.localizedDescription),
                "uploadStorage": config.diarizationUploadStorage
            ])
            return nil
        }
    }

    private func finalizeDiarizationChunks() -> (logURL: URL?, directoryURL: URL?, count: Int) {
        guard let chunker = diarizationChunker else {
            return (sessionChunksLogURL, nil, 0)
        }
        let chunks = chunker.finishAndWait()
        diarizationChunker = nil
        for chunk in chunks {
            handleDiarizationChunkSealed(chunk)
        }
        appendEvent("diarization_chunks_finalized", fields: [
            "chunks": chunks.count,
            "chunksLogPath": chunker.chunksLogURL.path,
            "chunksDirectoryPath": chunker.chunksDirectoryURL.path
        ])
        return (chunker.chunksLogURL, chunker.chunksDirectoryURL, chunks.count)
    }

    private func handleDiarizationChunkSealed(_ chunk: DiarizationAudioChunk) {
        appendDiarizationChunkWaitingEvent(chunk)
        startDiarizationProcessingIfConfigured(chunk)
    }

    private func appendDiarizationChunkWaitingEvent(_ chunk: DiarizationAudioChunk) {
        guard !diarizationLoggedChunkIndices.contains(chunk.index) else { return }
        diarizationLoggedChunkIndices.insert(chunk.index)
        appendEvent("diarization_chunk_waiting_for_upload", fields: [
            "chunkIndex": chunk.index,
            "startMilliseconds": chunk.startMilliseconds,
            "endMilliseconds": chunk.endMilliseconds,
            "localFile": chunk.localURL.lastPathComponent,
            "state": chunk.state.rawValue,
            "reason": diarizationPipeline == nil ? "upload_provider_not_configured" : "queued_for_upload"
        ])
    }

    /// 逐分片 LLM 纠错：用该时间窗前后的实时转写交叉验证 Fun-ASR 句子。
    /// 任何失败都返回原句（保守，不阻塞回填）。
    private func refineDiarizedSentences(
        chunk: DiarizationAudioChunk,
        sentences: [ProviderDiarizedSentence]
    ) async -> (sentences: [ProviderDiarizedSentence], corrections: Int) {
        guard !config.uiFixtureMode, let startDate = meetingStartDate else { return (sentences, 0) }
        let windowEnd = startDate.addingTimeInterval(TimeInterval(chunk.endMilliseconds) / 1_000 + 30)
        let realtimeContext = transcriptEntries
            .filter { $0.timestamp != .distantPast && $0.timestamp <= windowEnd }
            .map(\.text)
            .joined(separator: "\n")
        guard !realtimeContext.isEmpty else { return (sentences, 0) }

        let engine = makeAIEngine(fixtureMode: false)
        do {
            let raw = try await engine.rawCompletion(
                systemPrompt: TranscriptRefiner.buildSystemPrompt(),
                userContent: TranscriptRefiner.buildUserContent(sentences: sentences, realtimeContext: realtimeContext)
            )
            let refined = TranscriptRefiner.applyCorrections(raw, to: sentences)
            if refined.corrections > 0 {
                logger.info("Chunk \(chunk.index) refined: \(refined.corrections) corrections")
            }
            return refined
        } catch {
            logger.warning("Chunk \(chunk.index) refine failed, keeping original: \(error.localizedDescription)")
            return (sentences, 0)
        }
    }

    private func startDiarizationProcessingIfConfigured(_ chunk: DiarizationAudioChunk) {
        guard let pipeline = diarizationPipeline else { return }
        guard !diarizationProcessingChunkIndices.contains(chunk.index) else { return }
        diarizationProcessingChunkIndices.insert(chunk.index)
        appendEvent("diarization_chunk_upload_queued", fields: [
            "chunkIndex": chunk.index,
            "localFile": chunk.localURL.lastPathComponent
        ])
        let sessionGeneration = diarizationSessionGate.currentGeneration
        let task = Task { @MainActor [weak self] in
            do {
                _ = try await pipeline.process(chunk)
            } catch {
                guard let self, self.diarizationSessionGate.accepts(sessionGeneration) else { return }
                let safeError = DiarizationLogSanitizer.redactSensitiveText(error.localizedDescription)
                self.appendSystemMessage("说话人分离分片 \(chunk.index) 处理失败：\(safeError)")
            }
        }
        diarizationProcessingTasks.append(task)
    }

    private func appendToSessionFile(text: String, timestamp: Date) {
        guard let url = sessionFileURL else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: timestamp))] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let fh = try FileHandle(forWritingTo: url)
                defer { try? fh.close() }
                try fh.seekToEnd()
                try fh.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            logger.error("Failed to append transcript to session file: \(url.path), error=\(error.localizedDescription)")
            appendEvent("transcript_txt_append_failed", fields: ["path": url.path, "error": error.localizedDescription])
        }
    }

    private func writeTranscriptMarkdownSnapshot() {
        guard let url = sessionTranscriptMarkdownURL else { return }
        do {
            try TranscriptMarkdownWriter.writeSnapshot(
                entries: transcriptEntries,
                speakerBackfillSegments: speakerBackfillSegments,
                to: url
            )
        } catch {
            logger.error("Failed to write transcript markdown: \(url.path), error=\(error.localizedDescription)")
        }
    }

    private func cancelDiarizationProcessingTasks(reason: String) {
        guard !diarizationProcessingTasks.isEmpty else { return }
        let count = diarizationProcessingTasks.count
        for task in diarizationProcessingTasks {
            task.cancel()
        }
        diarizationProcessingTasks.removeAll()
        diarizationProcessingChunkIndices.removeAll()
        appendEvent("diarization_processing_tasks_cancelled", fields: [
            "reason": reason,
            "tasks": count
        ])
    }

    private func appendEvent(_ event: String, fields: [String: Any] = [:]) {
        guard let url = sessionEventLogURL else { return }

        var payload: [String: Any] = [
            "timestamp": Self.eventTimestampFormatter.string(from: Date()),
            "event": event
        ]
        for (key, value) in fields {
            payload[key] = jsonSafeEventValue(value)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            guard let lineData = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                let fh = try FileHandle(forWritingTo: url)
                defer { try? fh.close() }
                try fh.seekToEnd()
                try fh.write(contentsOf: lineData)
            } else {
                try lineData.write(to: url)
            }
        } catch {
            logger.error("Failed to append session event: event=\(event), path=\(url.path), error=\(error.localizedDescription)")
        }
    }

    private func jsonSafeEventValue(_ value: Any) -> Any {
        switch value {
        case let value as String:
            return sanitizeEventString(value)
        case let value as Int:
            return value
        case let value as Double:
            return value.isFinite ? value : String(value)
        case let value as Float:
            return value.isFinite ? Double(value) : String(value)
        case let value as Bool:
            return value
        case let value as [String]:
            return value.map(sanitizeEventString)
        case let value as Date:
            return Self.eventTimestampFormatter.string(from: value)
        default:
            return sanitizeEventString(String(describing: value))
        }
    }

    private func sanitizeEventString(_ value: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let homeSafe = homePath.isEmpty ? value : value.replacingOccurrences(of: homePath, with: "~")
        return DiarizationLogSanitizer.redactSensitiveText(homeSafe)
    }

    private func meetingConfigEventFields() -> [String: Any] {
        [
            "asrServerPort": config.asrServerPort,
            "asrLanguage": config.asrLanguage,
            "aiMode": aiMode.rawValue,
            "aiModel": config.aiModel,
            "aiBaseURLHost": URL(string: config.aiBaseURL)?.host ?? "unknown",
            "analysisBackend": currentAnalysisBackend().rawValue,
            "dashscopeCredentialLoaded": !config.dashscopeAPIKey.isEmpty,
            "aiCredentialLoaded": !config.aiAPIKey.isEmpty,
            "fixture": config.uiFixtureMode,
            "sessionsDirectory": config.sessionsDirectory.path,
            "segmentedDiarizationEnabled": config.segmentedDiarizationEnabled,
            "diarizationChunkDurationSeconds": config.diarizationChunkDurationSeconds,
            "diarizationProvider": config.diarizationProvider,
            "diarizationUploadStorage": config.diarizationUploadStorage,
            "diarizationUploadRegion": config.diarizationUploadRegion,
            "diarizationUploadEndpointHost": URL(string: config.diarizationUploadEndpoint)?.host ?? config.diarizationUploadEndpoint,
            "diarizationUploadBucketConfigured": !config.diarizationUploadBucket.isEmpty,
            "diarizationUploadConfigured": !config.diarizationUploadStorage.isEmpty && config.diarizationUploadStorage != "unconfigured",
            "ossCredentialLoaded": !config.ossAccessKeyID.isEmpty && !config.ossAccessKeySecret.isEmpty
        ]
    }

    private static let eventTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
            case .system: prefix = "🔧 [系统]"
            }
            let backendSuffix: String
            if let execution = card.execution {
                backendSuffix = " _[\(execution.statusText)]_"
            } else {
                backendSuffix = ""
            }
            if let query = card.userQuery {
                lines.append("- [\(formatter.string(from: card.timestamp))] \(prefix) 用户问: \(query)\n  \(card.content)\(pin)\(backendSuffix)\n")
            } else {
                lines.append("- [\(formatter.string(from: card.timestamp))] \(prefix) \(card.content)\(pin)\(backendSuffix)\n")
            }
        }

        let text = lines.joined(separator: "\n")
        do {
            try text.write(to: aiLogURL, atomically: true, encoding: .utf8)
            logger.info("AI log saved to \(aiLogURL.path), \(self.insightCards.count) cards, \(pinned.count) pinned")
            appendEvent("ai_log_saved", fields: [
                "path": aiLogURL.path,
                "cards": insightCards.count,
                "pinned": pinned.count
            ])
        } catch {
            logger.error("Failed to save AI log: \(error.localizedDescription)")
            appendEvent("ai_log_save_failed", fields: ["path": aiLogURL.path, "error": error.localizedDescription])
        }
    }

    // MARK: - Step D: ASR reconnect

    private func configureASRClient(_ client: ASRClient, generation: Int) {
        client.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor [weak self] in
                guard let self, self.asrClientGeneration == generation else { return }
                self.handleTranscript(text: text, isFinal: isFinal)
            }
        }
        client.onError = { [weak self] errorMsg in
            Task { @MainActor [weak self] in
                guard let self, self.asrClientGeneration == generation else { return }
                self.handleASRError(errorMsg)
            }
        }
        client.onEvent = { [weak self] event, fields in
            Task { @MainActor [weak self] in
                guard let self, self.asrClientGeneration == generation else { return }
                self.handleASRClientEvent(event, fields: fields)
            }
        }
    }

    private func handleASRClientEvent(_ event: String, fields: [String: String]) {
        let eventFields = fields.reduce(into: [String: Any]()) { result, item in
            result[item.key] = item.value
        }
        appendEvent("asr_client_\(event)", fields: eventFields)

        if event == "session_started" {
            if asrReconnectCount > 0 {
                appendEvent("asr_reconnect_succeeded", fields: [
                    "attempt": asrReconnectCount,
                    "backoffSeconds": asrReconnectBackoffSeconds
                ])
            }
            resetASRReconnectState(reason: "session_started", logEvent: asrReconnectCount > 0)
        }
    }

    private func handleASRError(_ message: String) {
        let isConnectionError = message.contains("WebSocket 接收错误")
            || message.contains("ASR Bridge 错误")
            || message.contains("connection") || message.contains("Connection")
        logger.warning("ASR error received: reconnectable=\(isConnectionError), count=\(self.asrReconnectCount), message=\(message)")
        appendEvent("asr_error", fields: [
            "reconnectable": isConnectionError,
            "reconnectCount": asrReconnectCount,
            "message": String(message.prefix(500))
        ])

        guard isConnectionError, isRecording else {
            appendEvent("asr_reconnect_not_attempted", fields: [
                "reconnectable": isConnectionError,
                "isRecording": isRecording,
                "reconnectCount": asrReconnectCount,
                "maxAttempts": maxASRReconnects
            ])
            appendSystemMessage("ASR 错误: \(message)")
            return
        }

        if asrReconnectGaveUp {
            appendEvent("asr_reconnect_deduplicated", fields: [
                "reason": "already_gave_up",
                "reconnectCount": asrReconnectCount,
                "maxAttempts": maxASRReconnects
            ])
            return
        }

        if asrReconnectTask != nil {
            appendEvent("asr_reconnect_deduplicated", fields: [
                "reason": "task_in_progress",
                "reconnectCount": asrReconnectCount,
                "delaySeconds": asrReconnectBackoffSeconds
            ])
            logger.debug("ASR reconnect already scheduled, deduplicating error")
            return
        }

        guard asrReconnectCount < maxASRReconnects else {
            asrReconnectGaveUp = true
            appendEvent("asr_reconnect_give_up", fields: [
                "reconnectCount": asrReconnectCount,
                "maxAttempts": maxASRReconnects,
                "lastError": String(message.prefix(500))
            ])
            appendSystemMessage("ASR 多次重连失败，已暂停自动重连。请结束会议后重新开始，或检查网络和 ASR 服务。")
            return
        }

        asrReconnectCount += 1
        let reconnectDelay = asrReconnectBackoffSeconds
        appendEvent("asr_reconnect_scheduled", fields: [
            "attempt": asrReconnectCount,
            "maxAttempts": maxASRReconnects,
            "delaySeconds": reconnectDelay
        ])
        appendSystemMessage("ASR 连接中断，\(Int(reconnectDelay)) 秒后重连（\(asrReconnectCount)/\(maxASRReconnects)）…")

        asrReconnectBackoffSeconds = min(asrReconnectBackoffSeconds * 2, maxASRReconnectBackoffSeconds)
        asrReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.reconnectASR()
        }
    }

    private func reconnectASR() async {
        guard isRecording else {
            cancelPendingASRReconnect(reason: "not_recording")
            return
        }
        logger.info("Reconnecting ASR client on port \(self.config.asrServerPort)")
        appendEvent("asr_reconnect_started", fields: [
            "port": config.asrServerPort,
            "attempt": asrReconnectCount
        ])
        let oldClient = asrClient
        asrClient = nil
        oldClient?.disconnect(gracePeriod: 0.2)

        let client = ASRClient()
        asrClientGeneration += 1
        configureASRClient(client, generation: asrClientGeneration)
        client.connect(port: config.asrServerPort)
        asrClient = client
        asrReconnectTask = nil
        appendEvent("asr_reconnect_client_started", fields: [
            "port": config.asrServerPort,
            "attempt": asrReconnectCount
        ])
        appendSystemMessage("ASR 正在重新连接…")
    }

    private func resetASRReconnectState(reason: String, logEvent: Bool) {
        asrReconnectTask?.cancel()
        asrReconnectTask = nil
        asrReconnectCount = 0
        asrReconnectBackoffSeconds = initialASRReconnectBackoffSeconds
        asrReconnectGaveUp = false
        if logEvent {
            appendEvent("asr_reconnect_state_reset", fields: ["reason": reason])
        }
    }

    private func cancelPendingASRReconnect(reason: String) {
        guard asrReconnectTask != nil else { return }
        asrReconnectTask?.cancel()
        asrReconnectTask = nil
        appendEvent("asr_reconnect_cancelled", fields: ["reason": reason])
    }

    // MARK: - Step E: Smart trigger

    private func startTimers() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingDuration += 1
            }
        }
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkASRResultsWatchdog()
                self?.checkSilenceTrigger()
            }
        }
    }

    /// 转写结果停摆检测：音频在流动但识别结果长时间为零（服务端静默降级）时轮换 ASR 会话
    private func checkASRResultsWatchdog() {
        guard ASRResultsWatchdog.standard.shouldRotate(
            now: Date(),
            isRecording: isRecording,
            lastTranscriptAt: lastTranscriptTime,
            meetingStartAt: meetingStartDate,
            lastRotateAt: lastWatchdogRotateAt
        ) else { return }
        lastWatchdogRotateAt = Date()
        let baseline = max(lastTranscriptTime, meetingStartDate ?? .distantPast)
        let stallSeconds = Int(Date().timeIntervalSince(baseline))
        logger.warning("ASR results watchdog: no transcript for \(stallSeconds)s while recording, rotating stream")
        appendEvent("asr_results_watchdog_rotated", fields: ["stallSeconds": stallSeconds])
        appendSystemMessage("转写结果停滞 \(stallSeconds) 秒，已自动重连语音识别")
        Task { @MainActor [weak self] in
            await self?.reconnectASR()
        }
    }

    private func checkSilenceTrigger() {
        guard isRecording, !isAnalyzing else { return }
        let newChars = totalTranscriptLength() - lastAnalysisTextLength
        guard newChars > 0 else { return }

        let silenceDuration = Date().timeIntervalSince(lastTranscriptTime)
        let timeSinceLastAnalysis = Date().timeIntervalSince(lastAnalysisTime)

        let silenceThreshold: TimeInterval
        let minNewChars: Int
        switch aiMode {
        case .observer:
            return
        case .advisor:
            silenceThreshold = 60
            minNewChars = 50
        case .researcher:
            silenceThreshold = 30
            minNewChars = 30
        }

        let silenceTrigger = silenceDuration > silenceThreshold && newChars >= minNewChars
        let ceilingTrigger = timeSinceLastAnalysis > 600 && newChars >= minNewChars

        if silenceTrigger || ceilingTrigger {
            logger.info("Auto trigger: silence=\(silenceTrigger) ceiling=\(ceilingTrigger) newChars=\(newChars)")
            triggerAnalysis(source: silenceTrigger ? "silence" : "ceiling")
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
            modeInstruction = "你处于顾问模式。默认保持沉默（should_speak 设为 false）；仅当出现关键盲点、方向性风险、明确行动项或真正的新信息时才发言。不要复述共识、不要为了总结而总结、不要刷存在感。"
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
        1. 先判断「这里有什么真正值得说的？」— 如果没有，should_speak 设为 false；宁可沉默，也不要输出低信息量内容
        2. 有内容时，选一个最想深挖的角度切入
        3. 观察之后，主动说出值得追问或讨论的方向
        4. kind 通常是 "insight"，阶段小结时用 "summary"
        5. topic_keywords 提取 3-5 个当前讨论的核心关键词
        6. 不要重复上次说过的内容\(synthNote)
        """
    }

    /// Total text length across all transcript entries (partial + final)
    private func totalTranscriptLength() -> Int {
        transcriptEntries.reduce(0) { $0 + $1.text.count }
    }

    private func buildAnalysisUserContent() -> String {
        let snapshot = MeetingContextBuilder.buildSnapshot(
            transcriptEntries: transcriptEntries,
            insightCards: insightCards
        )
        logger.debug(
            "Context snapshot built: hot=\(snapshot.hotEntryCount), recent=\(snapshot.recentEntryCount), durable=\(snapshot.durableMemoryItemCount), chars=\(snapshot.promptLength)"
        )
        return snapshot.promptText
    }

    private func currentAnalysisBackend() -> AnalysisBackendMode {
        if let envValue = ProcessInfo.processInfo.environment["MEETINGAI_ANALYSIS_BACKEND"],
           let envBackend = AnalysisBackendMode(rawValue: envValue) {
            return envBackend
        }
        let rawValue = UserDefaults.standard.string(forKey: "analysisBackend")
        // 默认 HTTP：Codex CLI 洞察实测 50s+ 延迟，降级为设置里的可选项（2026-07-18 用户决策）
        return AnalysisBackendMode(rawValue: rawValue ?? "") ?? .http
    }

    private func makeAIEngine(fixtureMode: Bool) -> AIEngine {
        AIEngine(
            apiKey: fixtureMode ? "fixture" : config.aiAPIKey,
            model: fixtureMode ? "fixture" : config.aiModel,
            baseURL: fixtureMode ? "fixture://local" : config.aiBaseURL,
            fixtureMode: fixtureMode,
            backend: currentAnalysisBackend()
        )
    }

    private func userFacingErrorMessage(_ error: Error) -> String {
        if let aiError = error as? AIEngine.AIError {
            return aiError.localizedDescription
        }
        return error.localizedDescription
    }

    private func failureStatusText(stage: String, backend: AnalysisBackendMode, error: Error) -> String {
        "最近失败：\(stage) · \(backend.displayName) · \(userFacingErrorMessage(error))"
    }

    private static let fixtureTranscriptLines = [
        "提问者在描述企业家私董会里的核心困惑，希望得到更高质量的追问。",
        "讨论聚焦在主持流程、提问轮次和记录方式是否足够支撑后续复盘。",
        "现场希望 AI 只在必要时提醒盲点，而不是频繁打断讨论。"
    ]
}
