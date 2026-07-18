import AlibabaCloudOSS
import Foundation
import os.log

private let ossUploaderLogger = Logger(subsystem: "MeetingAI", category: "DiarizationOSS")

final class DiarizationOSSUploader: DiarizationAudioUploader {
    private let config: DiarizationOSSUploadConfiguration
    private let sessionStem: String
    private let client: Client

    init(config: DiarizationOSSUploadConfiguration, sessionStem: String) throws {
        guard config.isReady else {
            throw DiarizationUploadError.missingConfiguration(config.missingConfigurationReason ?? "OSS upload is not configured")
        }
        self.config = config
        self.sessionStem = sessionStem

        let securityToken = config.sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = StaticCredentialsProvider(
            accessKeyId: config.accessKeyID,
            accessKeySecret: config.accessKeySecret,
            securityToken: securityToken?.isEmpty == false ? securityToken : nil
        )
        let sdkConfig = Configuration.default()
            .withCredentialsProvider(credentials)
            .withRegion(config.region)
            .withEndpoint(config.normalizedEndpoint)
            .withSignerVersion(.v4)
            .withTimeoutIntervalForRequest(60)
            .withTimeoutIntervalForResource(15 * 60)
        self.client = Client(sdkConfig)
    }

    func upload(_ request: DiarizationUploadRequest) async throws -> DiarizationUploadResult {
        let objectKey = DiarizationOSSObjectKeyBuilder.makeObjectKey(
            objectPrefix: config.normalizedObjectPrefix,
            sessionStem: sessionStem,
            chunk: request.chunk
        )
        let putRequest = PutObjectRequest(
            bucket: config.bucket,
            key: objectKey,
            contentType: request.contentType,
            body: .file(request.chunk.localURL)
        )
        let putResult = try await client.putObject(putRequest)
        ossUploaderLogger.info("OSS chunk uploaded: chunk=\(request.chunk.index), status=\(putResult.statusCode), objectKey=\(objectKey)")

        let expiration = Date().addingTimeInterval(config.clampedPresignTTLSeconds)
        let getRequest = GetObjectRequest(bucket: config.bucket, key: objectKey)
        let presigned = try await client.presign(getRequest, expiration)
        guard let remoteURL = URL(string: presigned.url) else {
            throw DiarizationUploadError.invalidRemoteURL
        }
        return DiarizationUploadResult(
            remoteFileURL: remoteURL,
            storageProvider: .oss,
            expiresAt: presigned.expiration,
            objectKey: objectKey
        )
    }
}

enum DiarizationUploadError: Error, CustomStringConvertible, LocalizedError {
    case missingConfiguration(String)
    case invalidRemoteURL

    var description: String {
        switch self {
        case .missingConfiguration(let reason):
            return reason
        case .invalidRemoteURL:
            return "OSS presigned URL is invalid"
        }
    }

    var errorDescription: String? {
        description
    }
}
