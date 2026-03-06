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

        // MP3 recording setup
        if let url = recordingURL {
            let mp3Settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEGLayer3,
                AVSampleRateKey: hardwareFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            if let file = try? AVAudioFile(forWriting: url, settings: mp3Settings) {
                // Use the file's actual processingFormat to build converter
                if let recConv = AVAudioConverter(from: hardwareFormat, to: file.processingFormat) {
                    self.recordingFile = file
                    self.recordingConverter = recConv
                    self.recordingURL = url
                    logger.info("MP3 recording: \(url.path), processingFormat=\(file.processingFormat)")
                } else {
                    logger.warning("Could not create recording converter, MP3 recording disabled")
                }
            } else {
                logger.warning("Could not create MP3 file at \(url.path), recording disabled")
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.convertAndSendASR(buffer: buffer)
            self?.writeToMP3(buffer: buffer)
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
        engine = nil
        asrConverter = nil
        recordingConverter = nil
        recordingFile = nil  // closes the file
        isRecording = false
        logger.info("Recording stopped, MP3 saved to: \(self.recordingURL?.path ?? "none")")
    }

    // MARK: - Private

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

    private func writeToMP3(buffer: AVAudioPCMBuffer) {
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
