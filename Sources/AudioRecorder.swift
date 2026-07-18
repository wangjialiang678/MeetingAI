import AVFoundation
import Combine
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "AudioRecorder")

class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private var engine: AVAudioEngine?
    private var asrConverter: AVAudioConverter?
    private var recordingConverter: AVAudioConverter?
    private var recordingFile: AVAudioFile?
    private let tapDrainGate = AudioTapDrainGate()

    var onAudioData: ((Data) -> Void)?
    private(set) var recordingURL: URL?

    func start(recordingURL: URL? = nil) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // ASR target: 16kHz mono PCM16 (existing)
        guard let asrFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else { throw RecorderError.formatError }

        guard let asrConv = AVAudioConverter(from: hardwareFormat, to: asrFormat) else {
            throw RecorderError.converterError
        }
        self.asrConverter = asrConv

        // Recording setup. macOS may not provide an MP3 encoder through AVAudioFile,
        // so fall back to a PCM WAV file with the same session prefix.
        if let url = recordingURL {
            configureRecordingFile(preferredURL: url, hardwareFormat: hardwareFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.tapDrainGate.perform {
                self?.convertAndSendASR(buffer: buffer)
                self?.writeRecording(buffer: buffer)
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
        logger.info("Recording started: hardware=\(hardwareFormat), target=16kHz mono PCM16")
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if !tapDrainGate.waitForIdle(timeout: 2.0) {
            logger.warning("Audio tap drain timed out after 2s; continuing stop to avoid blocking the meeting")
        }
        engine = nil
        asrConverter = nil
        recordingConverter = nil
        recordingFile = nil  // closes the file
        isRecording = false
        logger.info("Recording stopped, saved to: \(self.recordingURL?.path ?? "none")")
    }

    // MARK: - Private

    private func configureRecordingFile(preferredURL url: URL, hardwareFormat: AVAudioFormat) {
        let mp3Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEGLayer3,
            AVSampleRateKey: hardwareFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]

        if configureRecordingFile(url: url, settings: mp3Settings, hardwareFormat: hardwareFormat) {
            logger.info("MP3 recording enabled: \(url.path)")
            return
        }

        let wavURL = url.deletingPathExtension().appendingPathExtension("wav")
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: hardwareFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        if configureRecordingFile(url: wavURL, settings: wavSettings, hardwareFormat: hardwareFormat) {
            logger.info("WAV recording fallback enabled: \(wavURL.path)")
        } else {
            logger.warning("Could not create MP3 or WAV recording file, recording disabled")
        }
    }

    private func configureRecordingFile(url: URL, settings: [String: Any], hardwareFormat: AVAudioFormat) -> Bool {
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else {
            return false
        }
        guard let recConv = AVAudioConverter(from: hardwareFormat, to: file.processingFormat) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        self.recordingFile = file
        self.recordingConverter = recConv
        self.recordingURL = url
        logger.info("Recording file configured: \(url.path), processingFormat=\(file.processingFormat)")
        return true
    }

    private func convertAndSendASR(buffer: AVAudioPCMBuffer) {
        guard let converter = asrConverter else { return }
        guard let asrFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        ) else { return }

        let ratio = asrFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: asrFormat, frameCapacity: outputFrameCount) else { return }

        var inputConsumed = false
        let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if inputConsumed { outStatus.pointee = .noDataNow; return nil }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if (status == .haveData || status == .inputRanDry), let channelData = outputBuffer.int16ChannelData {
            let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: channelData[0], count: byteCount)
            onAudioData?(data)
        }
    }

    private func writeRecording(buffer: AVAudioPCMBuffer) {
        guard let file = recordingFile, let converter = recordingConverter else { return }
        let procFormat = file.processingFormat
        let ratio = procFormat.sampleRate / buffer.format.sampleRate
        let outFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outFrameCount > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: outFrameCount) else { return }

        var inputConsumed = false
        converter.convert(to: outBuffer, error: nil) { _, outStatus in
            if inputConsumed { outStatus.pointee = .noDataNow; return nil }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        try? file.write(from: outBuffer)
    }

    enum RecorderError: LocalizedError {
        case formatError
        case converterError

        var errorDescription: String? {
            switch self {
            case .formatError: return "无法创建目标音频格式"
            case .converterError: return "无法创建音频格式转换器"
            }
        }
    }
}

final class AudioTapDrainGate {
    private let condition = NSCondition()
    private var inFlightCallbacks = 0

    func perform(_ work: () -> Void) {
        condition.lock()
        inFlightCallbacks += 1
        condition.unlock()

        defer {
            condition.lock()
            inFlightCallbacks -= 1
            condition.broadcast()
            condition.unlock()
        }

        work()
    }

    @discardableResult
    func waitForIdle(timeout: TimeInterval? = nil) -> Bool {
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        condition.lock()
        defer { condition.unlock() }
        while inFlightCallbacks > 0 {
            if let deadline {
                if !condition.wait(until: deadline) {
                    return inFlightCallbacks == 0
                }
            } else {
                condition.wait()
            }
        }
        return true
    }
}
