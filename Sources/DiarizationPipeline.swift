import Foundation
import os.log

private let diarizationPipelineLogger = Logger(subsystem: "MeetingAI", category: "DiarizationPipeline")

actor DiarizationPipeline {
    private let sessionFileURL: URL
    private let eventLogURL: URL
    private let language: String
    private let uploader: DiarizationAudioUploader
    private let provider: DiarizationTranscriptionProvider
    private let speakerCount: Int?
    private let onSegmentsUpdated: (([DiarizedTranscriptSegment]) -> Void)?

    private var completedResults: [Int: DiarizationChunkResult] = [:]

    init(
        sessionFileURL: URL,
        eventLogURL: URL,
        language: String,
        uploader: DiarizationAudioUploader,
        provider: DiarizationTranscriptionProvider,
        speakerCount: Int? = nil,
        onSegmentsUpdated: (([DiarizedTranscriptSegment]) -> Void)? = nil
    ) {
        self.sessionFileURL = sessionFileURL
        self.eventLogURL = eventLogURL
        self.language = language
        self.uploader = uploader
        self.provider = provider
        self.speakerCount = speakerCount
        self.onSegmentsUpdated = onSegmentsUpdated
    }

    @discardableResult
    func process(_ chunk: DiarizationAudioChunk) async throws -> DiarizationChunkResult {
        do {
            appendEvent("diarization_upload_started", fields: [
                "chunkIndex": chunk.index,
                "localFile": chunk.localURL.lastPathComponent,
                "contentType": "audio/wav"
            ])

            let upload = try await uploader.upload(DiarizationUploadRequest(chunk: chunk, contentType: "audio/wav"))
            appendEvent("diarization_upload_completed", fields: [
                "chunkIndex": chunk.index,
                "remoteFile": DiarizationLogSanitizer.describeRemoteURL(upload.remoteFileURL),
                "objectKey": upload.objectKey ?? "",
                "expiresAt": upload.expiresAt as Any
            ])

            let transcriptionRequest = DiarizationTranscriptionRequest(
                chunk: chunk,
                remoteFileURL: upload.remoteFileURL,
                language: language,
                diarizationEnabled: true,
                speakerCount: speakerCount
            )
            let task = try await provider.submit(transcriptionRequest)
            appendEvent("diarization_task_submitted", fields: [
                "chunkIndex": chunk.index,
                "taskID": task.taskID,
                "provider": task.provider.rawValue,
                "remoteFile": DiarizationLogSanitizer.describeRemoteURL(task.remoteFileURL)
            ])

            let result = try await provider.waitForResult(task: task, chunk: chunk)
            completedResults[chunk.index] = result
            appendEvent("diarization_task_completed", fields: [
                "chunkIndex": chunk.index,
                "taskID": task.taskID,
                "sentences": result.sentences.count
            ])

            let merged = DiarizationMerger.merge(results: completedResults.values.sorted {
                $0.chunk.index < $1.chunk.index
            })
            let persisted = try DiarizationBackfillWriter.persist(
                segments: merged,
                sessionFileURL: sessionFileURL,
                eventLogURL: eventLogURL
            )
            appendEvent("diarization_merge_completed", fields: [
                "chunks": completedResults.count,
                "segments": merged.count,
                "diarizedFile": persisted.diarizedJSONLURL.lastPathComponent,
                "transcriptMarkdownFile": persisted.transcriptMarkdownURL.lastPathComponent
            ])
            if let onSegmentsUpdated {
                await MainActor.run {
                    onSegmentsUpdated(merged)
                }
            }
            diarizationPipelineLogger.info("Diarization chunk processed: chunk=\(chunk.index), sentences=\(result.sentences.count), merged=\(merged.count)")
            return result
        } catch {
            let safeError = DiarizationLogSanitizer.redactSensitiveText(error.localizedDescription)
            appendEvent("diarization_task_failed", fields: [
                "chunkIndex": chunk.index,
                "localFile": chunk.localURL.lastPathComponent,
                "error": safeError
            ])
            diarizationPipelineLogger.error("Diarization chunk failed: chunk=\(chunk.index), error=\(safeError)")
            throw error
        }
    }

    private func appendEvent(_ event: String, fields: [String: Any] = [:]) {
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
            if FileManager.default.fileExists(atPath: eventLogURL.path) {
                let handle = try FileHandle(forWritingTo: eventLogURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try FileManager.default.createDirectory(
                    at: eventLogURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try lineData.write(to: eventLogURL)
            }
        } catch {
            diarizationPipelineLogger.error("Failed to append diarization pipeline event: \(error.localizedDescription)")
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

    private static let eventTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
