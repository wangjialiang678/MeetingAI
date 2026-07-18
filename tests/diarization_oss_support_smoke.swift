import Foundation

enum DiarizationOSSSupportSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct DiarizationOSSSupportSmoke {
    static func main() {
        do {
            try testOSSConfigReadinessAndEndpointNormalization()
            try testOSSObjectKeyDoesNotLeakLocalPath()
            print("Diarization OSS support smoke tests PASS")
        } catch {
            fputs("Diarization OSS support smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw DiarizationOSSSupportSmokeFailure.failed(message)
        }
    }

    private static func testOSSConfigReadinessAndEndpointNormalization() throws {
        let configured = DiarizationOSSUploadConfiguration(
            region: "cn-beijing",
            endpoint: "https://oss-cn-beijing.aliyuncs.com",
            bucket: "meetingai-private",
            objectPrefix: "meetingai/chunks",
            accessKeyID: "fake-ak",
            accessKeySecret: "fake-sk",
            sessionToken: "",
            presignTTLSeconds: 7_200
        )
        let missingSecret = DiarizationOSSUploadConfiguration(
            region: "cn-beijing",
            endpoint: "oss-cn-beijing.aliyuncs.com",
            bucket: "meetingai-private",
            objectPrefix: "meetingai/chunks",
            accessKeyID: "fake-ak",
            accessKeySecret: "",
            sessionToken: nil,
            presignTTLSeconds: 7_200
        )

        try expect(configured.isReady, "complete OSS upload config should be ready")
        try expect(configured.normalizedEndpoint == "oss-cn-beijing.aliyuncs.com", "OSS endpoint should strip URL scheme for SDK config")
        try expect(configured.normalizedObjectPrefix == "meetingai/chunks", "object prefix should trim slashes")
        try expect(!missingSecret.isReady, "missing OSS secret should not be ready")
        try expect(missingSecret.missingConfigurationReason?.contains("credentials") == true, "missing reason should identify credentials")
    }

    private static func testOSSObjectKeyDoesNotLeakLocalPath() throws {
        let chunk = DiarizationAudioChunk(
            index: 12,
            startMilliseconds: 120_000,
            endMilliseconds: 180_000,
            localURL: URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/MeetingAI/sessions/2026-05-23-20-00-00-chunks/chunk-0012.wav"),
            state: .waitingForUpload
        )
        let key = DiarizationOSSObjectKeyBuilder.makeObjectKey(
            objectPrefix: "/meetingai/chunks/",
            sessionStem: "2026-05-23-20-00-00",
            chunk: chunk
        )

        try expect(key == "meetingai/chunks/2026-05-23-20-00-00/2026-05-23-20-00-00-chunk-0012.wav", "object key should be deterministic")
        try expect(!key.contains(NSHomeDirectory()), "object key should not include local home path")
        try expect(!key.contains("Application Support"), "object key should not include local directory names")
    }
}
