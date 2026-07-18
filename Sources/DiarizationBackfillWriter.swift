import Foundation

struct DiarizationBackfillResult: Equatable {
    let diarizedJSONLURL: URL
    let transcriptMarkdownURL: URL
    let segmentCount: Int
}

enum DiarizationBackfillWriter {
    static func persist(
        segments: [DiarizedTranscriptSegment],
        sessionFileURL: URL,
        eventLogURL: URL? = nil
    ) throws -> DiarizationBackfillResult {
        let sortedSegments = segments.sorted {
            if $0.beginMilliseconds != $1.beginMilliseconds {
                return $0.beginMilliseconds < $1.beginMilliseconds
            }
            if $0.endMilliseconds != $1.endMilliseconds {
                return $0.endMilliseconds < $1.endMilliseconds
            }
            return $0.chunkIndex < $1.chunkIndex
        }

        let diarizedURL = sessionFileURL.deletingPathExtension().appendingPathExtension("diarized.jsonl")
        let transcriptMarkdownURL = sessionFileURL.deletingPathExtension().appendingPathExtension("transcript.md")

        try writeJSONL(segments: sortedSegments, to: diarizedURL)
        try appendSpeakerBackfill(segments: sortedSegments, to: transcriptMarkdownURL)
        if let eventLogURL {
            try appendBackfillSavedEvent(
                to: eventLogURL,
                diarizedURL: diarizedURL,
                transcriptMarkdownURL: transcriptMarkdownURL,
                segmentCount: sortedSegments.count
            )
        }

        return DiarizationBackfillResult(
            diarizedJSONLURL: diarizedURL,
            transcriptMarkdownURL: transcriptMarkdownURL,
            segmentCount: sortedSegments.count
        )
    }

    private static func writeJSONL(segments: [DiarizedTranscriptSegment], to url: URL) throws {
        let lines = try segments.map { segment in
            let payload: [String: Any] = [
                "beginMilliseconds": segment.beginMilliseconds,
                "endMilliseconds": segment.endMilliseconds,
                "speakerID": segment.speakerID,
                "text": segment.text,
                "chunkIndex": segment.chunkIndex
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        try lines.joined(separator: "\n").appending(lines.isEmpty ? "" : "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func appendSpeakerBackfill(segments: [DiarizedTranscriptSegment], to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# 会议转写\n"
        let base = removeExistingSpeakerBackfill(from: existing)
        var lines = [base.trimmingCharacters(in: .whitespacesAndNewlines), "", "## 说话人分离回填", ""]

        if segments.isEmpty {
            lines.append("_暂无说话人分离结果_")
        } else {
            for segment in segments {
                let text = segment.text.replacingOccurrences(of: "\n", with: " ")
                lines.append("- [\(formatMilliseconds(segment.beginMilliseconds)) - \(formatMilliseconds(segment.endMilliseconds))] \(segment.speakerID)：\(text)")
            }
        }

        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func appendBackfillSavedEvent(
        to eventLogURL: URL,
        diarizedURL: URL,
        transcriptMarkdownURL: URL,
        segmentCount: Int
    ) throws {
        let payload: [String: Any] = [
            "timestamp": timestampFormatter.string(from: Date()),
            "event": "diarization_backfill_saved",
            "segments": segmentCount,
            "diarizedFile": diarizedURL.lastPathComponent,
            "transcriptMarkdownFile": transcriptMarkdownURL.lastPathComponent
        ]
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
    }

    private static func removeExistingSpeakerBackfill(from markdown: String) -> String {
        guard let range = markdown.range(of: "\n## 说话人分离回填") else {
            return markdown
        }
        return String(markdown[..<range.lowerBound])
    }

    private static func formatMilliseconds(_ milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        let totalSeconds = clamped / 1_000
        let ms = clamped % 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, ms)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
