import Foundation

enum DiarizationChunkLifecycleSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct DiarizationChunkLifecycleSmoke {
    static func main() {
        do {
            try testChunkLifecycleLogAndWAVOutput()
            try testFinalPartialChunkIsSealed()
            print("Diarization chunk lifecycle smoke tests PASS")
        } catch {
            fputs("Diarization chunk lifecycle smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw DiarizationChunkLifecycleSmokeFailure.failed(message)
        }
    }

    private static func makeTempSessionBase() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetingai-diarization-chunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("2026-05-23-18-00-00.txt")
    }

    private static func pcm16(milliseconds: Int, sampleRate: Int = 16_000, byte: UInt8 = 1) -> Data {
        let byteCount = sampleRate * 2 * milliseconds / 1_000
        return Data(repeating: byte, count: byteCount)
    }

    private static func testChunkLifecycleLogAndWAVOutput() throws {
        let sessionURL = try makeTempSessionBase()
        let chunker = DiarizationAudioChunker(
            sessionFileURL: sessionURL,
            chunkDurationMilliseconds: 1_000,
            sampleRate: 16_000
        )

        chunker.appendPCM16(pcm16(milliseconds: 500, byte: 1))
        chunker.appendPCM16(pcm16(milliseconds: 500, byte: 2))
        let chunks = chunker.finishAndWait()

        try expect(chunks.count == 1, "expected one sealed chunk")
        try expect(chunks[0].index == 0, "chunk index should start at zero")
        try expect(chunks[0].startMilliseconds == 0, "chunk start should be session-relative zero")
        try expect(chunks[0].endMilliseconds == 1_000, "chunk end should match duration")
        try expect(chunks[0].state == .waitingForUpload, "chunk should wait for upload provider")

        let chunkBytes = try Data(contentsOf: chunks[0].localURL)
        try expect(chunkBytes.count > 44, "chunk wav file should contain header and audio data")
        try expect(String(data: chunkBytes.prefix(4), encoding: .ascii) == "RIFF", "wav file should start with RIFF")
        try expect(String(data: chunkBytes.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE", "wav file should contain WAVE marker")

        let lifecycleLog = sessionURL.deletingPathExtension().appendingPathExtension("chunks.jsonl")
        let logText = try String(contentsOf: lifecycleLog, encoding: .utf8)
        try expect(logText.contains("\"event\":\"chunk_created\""), "chunk log should contain created event")
        try expect(logText.contains("\"event\":\"chunk_waiting_for_upload\""), "chunk log should contain waiting event")
        try expect(logText.contains("\"chunkIndex\":0"), "chunk log should include chunk index")
        try expect(logText.contains("Waiting for upload processing"), "waiting event should use neutral processing message")
        try expect(!logText.contains("Upload provider is not configured"), "waiting event should not claim provider is unconfigured")
        try expect(!logText.contains(NSHomeDirectory()), "chunk log should not contain absolute home path")
    }

    private static func testFinalPartialChunkIsSealed() throws {
        let sessionURL = try makeTempSessionBase()
        let chunker = DiarizationAudioChunker(
            sessionFileURL: sessionURL,
            chunkDurationMilliseconds: 1_000,
            sampleRate: 16_000
        )

        chunker.appendPCM16(pcm16(milliseconds: 2_500, byte: 3))
        let chunks = chunker.finishAndWait()

        try expect(chunks.map(\.startMilliseconds) == [0, 1_000, 2_000], "chunk starts should be contiguous")
        try expect(chunks.map(\.endMilliseconds) == [1_000, 2_000, 2_500], "final partial chunk should preserve actual end time")
        try expect(chunks.allSatisfy { FileManager.default.fileExists(atPath: $0.localURL.path) }, "all chunk wav files should exist")
    }
}
