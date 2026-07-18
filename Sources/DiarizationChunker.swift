import Foundation
import os.log

private let diarizationChunkerLogger = Logger(subsystem: "MeetingAI", category: "DiarizationChunker")

final class DiarizationAudioChunker {
    let chunksLogURL: URL
    let chunksDirectoryURL: URL

    var onChunkSealed: ((DiarizationAudioChunk) -> Void)?

    private let chunkDurationMilliseconds: Int
    private let sampleRate: Int
    private let bytesPerSample = 2
    private let queue = DispatchQueue(label: "MeetingAI.DiarizationAudioChunker")
    private let sessionStem: String

    private var pendingPCM = Data()
    private var nextChunkIndex = 0
    private var nextChunkStartMilliseconds = 0
    private var sealedChunks: [DiarizationAudioChunk] = []
    private var isFinished = false

    init(
        sessionFileURL: URL,
        chunkDurationMilliseconds: Int = 60_000,
        sampleRate: Int = 16_000
    ) {
        self.chunkDurationMilliseconds = max(1, chunkDurationMilliseconds)
        self.sampleRate = max(1, sampleRate)
        self.chunksLogURL = sessionFileURL.deletingPathExtension().appendingPathExtension("chunks.jsonl")
        self.sessionStem = sessionFileURL.deletingPathExtension().lastPathComponent
        self.chunksDirectoryURL = sessionFileURL
            .deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent("\(sessionStem)-chunks", isDirectory: true)
    }

    func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.pendingPCM.append(data)
            self.sealCompleteChunks()
        }
    }

    @discardableResult
    func finishAndWait() -> [DiarizationAudioChunk] {
        queue.sync {
            guard !isFinished else { return sealedChunks }
            sealPendingChunkIfNeeded()
            isFinished = true
            diarizationChunkerLogger.info("Diarization chunker finished: chunks=\(self.sealedChunks.count)")
            return sealedChunks
        }
    }

    private var targetChunkBytes: Int {
        sampleRate * bytesPerSample * chunkDurationMilliseconds / 1_000
    }

    private func sealCompleteChunks() {
        let targetBytes = targetChunkBytes
        guard targetBytes > 0 else { return }
        while pendingPCM.count >= targetBytes {
            let chunkPCM = Data(pendingPCM.prefix(targetBytes))
            pendingPCM.removeFirst(targetBytes)
            sealChunk(pcmData: chunkPCM, durationMilliseconds: chunkDurationMilliseconds)
        }
    }

    private func sealPendingChunkIfNeeded() {
        guard !pendingPCM.isEmpty else { return }
        let pcm = pendingPCM
        pendingPCM.removeAll(keepingCapacity: false)
        sealChunk(pcmData: pcm, durationMilliseconds: milliseconds(forPCMByteCount: pcm.count))
    }

    private func sealChunk(pcmData: Data, durationMilliseconds: Int) {
        guard !pcmData.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: chunksDirectoryURL, withIntermediateDirectories: true)
            let index = nextChunkIndex
            let start = nextChunkStartMilliseconds
            let end = start + max(1, durationMilliseconds)
            let fileURL = chunksDirectoryURL.appendingPathComponent(String(format: "%@-chunk-%04d.wav", sessionStem, index))
            try makeWAVData(pcmData: pcmData).write(to: fileURL, options: .atomic)

            let createdChunk = DiarizationAudioChunk(
                index: index,
                startMilliseconds: start,
                endMilliseconds: end,
                localURL: fileURL,
                state: .created
            )
            appendLifecycleRecord(event: "chunk_created", chunk: createdChunk)

            let waitingChunk = DiarizationAudioChunk(
                index: index,
                startMilliseconds: start,
                endMilliseconds: end,
                localURL: fileURL,
                state: .waitingForUpload
            )
            appendLifecycleRecord(
                event: "chunk_waiting_for_upload",
                chunk: waitingChunk,
                message: "Waiting for upload processing"
            )

            sealedChunks.append(waitingChunk)
            nextChunkIndex += 1
            nextChunkStartMilliseconds = end
            onChunkSealed?(waitingChunk)
            diarizationChunkerLogger.info("Diarization chunk sealed: index=\(index), startMs=\(start), endMs=\(end), file=\(fileURL.lastPathComponent)")
        } catch {
            diarizationChunkerLogger.error("Failed to seal diarization chunk: \(error.localizedDescription)")
            appendFailureRecord(error: error.localizedDescription)
        }
    }

    private func milliseconds(forPCMByteCount byteCount: Int) -> Int {
        Int((Double(byteCount) / Double(sampleRate * bytesPerSample) * 1_000).rounded())
    }

    private func appendLifecycleRecord(
        event: String,
        chunk: DiarizationAudioChunk,
        message: String? = nil
    ) {
        var payload: [String: Any] = [
            "timestamp": Self.timestampFormatter.string(from: Date()),
            "event": event,
            "chunkIndex": chunk.index,
            "startMilliseconds": chunk.startMilliseconds,
            "endMilliseconds": chunk.endMilliseconds,
            "state": chunk.state.rawValue,
            "localFile": chunk.localURL.lastPathComponent
        ]
        if let message {
            payload["message"] = message
        }
        appendJSONLine(payload)
    }

    private func appendFailureRecord(error: String) {
        let payload: [String: Any] = [
            "timestamp": Self.timestampFormatter.string(from: Date()),
            "event": "chunk_failed",
            "chunkIndex": nextChunkIndex,
            "startMilliseconds": nextChunkStartMilliseconds,
            "state": DiarizationChunkState.failed.rawValue,
            "error": error
        ]
        appendJSONLine(payload)
    }

    private func appendJSONLine(_ payload: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            guard let lineData = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: chunksLogURL.path) {
                let handle = try FileHandle(forWritingTo: chunksLogURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try FileManager.default.createDirectory(
                    at: chunksLogURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try lineData.write(to: chunksLogURL)
            }
        } catch {
            diarizationChunkerLogger.error("Failed to append diarization chunk lifecycle record: \(error.localizedDescription)")
        }
    }

    private func makeWAVData(pcmData: Data) -> Data {
        let byteRate = sampleRate * bytesPerSample
        let blockAlign = UInt16(bytesPerSample)
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndianUInt32(UInt32(36 + pcmData.count))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndianUInt32(16)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt32(UInt32(sampleRate))
        data.appendLittleEndianUInt32(UInt32(byteRate))
        data.appendLittleEndianUInt16(blockAlign)
        data.appendLittleEndianUInt16(16)
        data.appendASCII("data")
        data.appendLittleEndianUInt32(UInt32(pcmData.count))
        data.append(pcmData)
        return data
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii) ?? Data())
    }

    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
