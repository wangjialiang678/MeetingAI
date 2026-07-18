import Foundation

enum DiarizationProviderBoundarySmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct DiarizationProviderBoundarySmoke {
    static func main() {
        do {
            try testProviderNeutralUploadAndTaskTypes()
            try testProviderConfigReadinessWithoutCredentialFields()
            print("Diarization provider boundary smoke tests PASS")
        } catch {
            fputs("Diarization provider boundary smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw DiarizationProviderBoundarySmokeFailure.failed(message)
        }
    }

    private static func testProviderNeutralUploadAndTaskTypes() throws {
        let chunk = DiarizationAudioChunk(
            index: 7,
            startMilliseconds: 70_000,
            endMilliseconds: 80_000,
            localURL: URL(fileURLWithPath: "/tmp/chunk-7.wav"),
            state: .waitingForUpload
        )
        let uploadRequest = DiarizationUploadRequest(
            chunk: chunk,
            contentType: "audio/wav"
        )
        let uploadResult = DiarizationUploadResult(
            remoteFileURL: URL(string: "https://example.com/chunk-7.wav")!,
            storageProvider: .oss,
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        let transcriptionRequest = DiarizationTranscriptionRequest(
            chunk: uploadRequest.chunk,
            remoteFileURL: uploadResult.remoteFileURL,
            language: "zh",
            diarizationEnabled: true
        )
        let task = DiarizationProviderTask(
            provider: .dashscopeFunASR,
            taskID: "fake-task-7",
            chunkIndex: chunk.index,
            state: .submitted,
            remoteFileURL: uploadResult.remoteFileURL
        )

        try expect(uploadRequest.localFileName == "chunk-7.wav", "upload request should expose local file name")
        try expect(transcriptionRequest.chunk.index == 7, "transcription request should preserve chunk identity")
        try expect(transcriptionRequest.diarizationEnabled, "transcription request should explicitly enable diarization")
        try expect(task.provider == .dashscopeFunASR, "provider task should preserve selected provider")
        try expect(task.remoteFileURL == uploadResult.remoteFileURL, "provider task should retain remote URL")
    }

    private static func testProviderConfigReadinessWithoutCredentialFields() throws {
        let unconfigured = DiarizationProviderConfig(
            provider: .dashscopeFunASR,
            uploadStorage: .unconfigured,
            uploadEndpoint: nil,
            uploadBucket: nil
        )
        let configured = DiarizationProviderConfig(
            provider: .dashscopeFunASR,
            uploadStorage: .oss,
            uploadEndpoint: "https://oss-cn-hangzhou.aliyuncs.com",
            uploadBucket: "meetingai-diarization"
        )

        try expect(!unconfigured.isReadyForRealUpload, "unconfigured storage should not be upload-ready")
        try expect(unconfigured.missingConfigurationReason?.contains("upload storage") == true, "missing reason should identify storage")
        try expect(configured.isReadyForRealUpload, "configured provider boundary should be upload-ready")

        let labels = Set(Mirror(reflecting: configured).children.compactMap(\.label))
        try expect(!labels.contains("apiKey"), "provider config should not carry API key fields")
        try expect(!labels.contains("secretKey"), "provider config should not carry storage secret fields")
        try expect(!labels.contains("accessKeySecret"), "provider config should not carry cloud secret fields")
    }
}
