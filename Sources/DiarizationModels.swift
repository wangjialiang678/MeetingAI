import Foundation

enum DiarizationChunkState: String, Codable {
    case created
    case waitingForUpload
    case submitted
    case completed
    case failed
}

struct DiarizationAudioChunk: Codable, Equatable {
    let index: Int
    let startMilliseconds: Int
    let endMilliseconds: Int
    let localURL: URL
    var state: DiarizationChunkState
    var taskID: String?
    var errorMessage: String?

    init(
        index: Int,
        startMilliseconds: Int,
        endMilliseconds: Int,
        localURL: URL,
        state: DiarizationChunkState = .created,
        taskID: String? = nil,
        errorMessage: String? = nil
    ) {
        self.index = index
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.localURL = localURL
        self.state = state
        self.taskID = taskID
        self.errorMessage = errorMessage
    }
}

struct ProviderDiarizedSentence: Codable, Equatable {
    let beginMilliseconds: Int
    let endMilliseconds: Int
    let speakerID: String
    let text: String
}

struct DiarizationChunkResult: Codable, Equatable {
    let chunk: DiarizationAudioChunk
    let sentences: [ProviderDiarizedSentence]
}

struct DiarizedTranscriptSegment: Codable, Equatable {
    let beginMilliseconds: Int
    let endMilliseconds: Int
    let speakerID: String
    let text: String
    let chunkIndex: Int
}

enum DiarizationMerger {
    static func merge(results: [DiarizationChunkResult]) -> [DiarizedTranscriptSegment] {
        let flattened = results.flatMap { result in
            result.sentences.map { sentence in
                DiarizedTranscriptSegment(
                    beginMilliseconds: result.chunk.startMilliseconds + sentence.beginMilliseconds,
                    endMilliseconds: result.chunk.startMilliseconds + sentence.endMilliseconds,
                    speakerID: sentence.speakerID,
                    text: sentence.text,
                    chunkIndex: result.chunk.index
                )
            }
        }

        var merged: [DiarizedTranscriptSegment] = []
        for segment in flattened.sorted(by: segmentSort) {
            if let duplicateIndex = merged.firstIndex(where: { isDuplicate($0, segment) }) {
                if segment.chunkIndex >= merged[duplicateIndex].chunkIndex {
                    merged[duplicateIndex] = segment
                    merged.sort(by: segmentSort)
                }
            } else {
                merged.append(segment)
            }
        }

        return merged.sorted(by: segmentSort)
    }

    private static func segmentSort(_ lhs: DiarizedTranscriptSegment, _ rhs: DiarizedTranscriptSegment) -> Bool {
        if lhs.beginMilliseconds != rhs.beginMilliseconds {
            return lhs.beginMilliseconds < rhs.beginMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.chunkIndex < rhs.chunkIndex
    }

    // 宁可保留重复也不误删真实发言：不同 speaker 的相同短句不视为重复。
    // 代价是跨 chunk speaker 重新编号时可能残留少量重复句，待跨 chunk speaker linking 后收敛。
    private static func isDuplicate(_ lhs: DiarizedTranscriptSegment, _ rhs: DiarizedTranscriptSegment) -> Bool {
        lhs.speakerID == rhs.speakerID
            && normalize(lhs.text) == normalize(rhs.text)
            && intervalsOverlap(lhs, rhs)
    }

    private static func intervalsOverlap(_ lhs: DiarizedTranscriptSegment, _ rhs: DiarizedTranscriptSegment) -> Bool {
        max(lhs.beginMilliseconds, rhs.beginMilliseconds) < min(lhs.endMilliseconds, rhs.endMilliseconds)
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}
