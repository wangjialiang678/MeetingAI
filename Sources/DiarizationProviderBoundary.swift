import Foundation

enum DiarizationProvider: String, Codable, Equatable {
    case dashscopeFunASR
    case fakeLocal
    case disabled
}

enum DiarizationUploadStorage: String, Codable, Equatable {
    case unconfigured
    case oss
    case presignedURL
}

struct DiarizationProviderConfig: Codable, Equatable {
    let provider: DiarizationProvider
    let uploadStorage: DiarizationUploadStorage
    let uploadEndpoint: String?
    let uploadBucket: String?

    var isReadyForRealUpload: Bool {
        guard provider != .disabled, uploadStorage != .unconfigured else {
            return false
        }
        switch uploadStorage {
        case .unconfigured:
            return false
        case .oss:
            return hasText(uploadEndpoint) && hasText(uploadBucket)
        case .presignedURL:
            return hasText(uploadEndpoint)
        }
    }

    var missingConfigurationReason: String? {
        if provider == .disabled {
            return "diarization provider is disabled"
        }
        if uploadStorage == .unconfigured {
            return "upload storage is not configured"
        }
        if uploadStorage == .oss && !hasText(uploadBucket) {
            return "upload bucket is not configured"
        }
        if !hasText(uploadEndpoint) {
            return "upload endpoint is not configured"
        }
        return nil
    }

    private func hasText(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct DiarizationUploadRequest: Equatable {
    let chunk: DiarizationAudioChunk
    let contentType: String

    var localFileName: String {
        chunk.localURL.lastPathComponent
    }
}

struct DiarizationUploadResult: Equatable {
    let remoteFileURL: URL
    let storageProvider: DiarizationUploadStorage
    let expiresAt: Date?
    let objectKey: String?

    init(
        remoteFileURL: URL,
        storageProvider: DiarizationUploadStorage,
        expiresAt: Date?,
        objectKey: String? = nil
    ) {
        self.remoteFileURL = remoteFileURL
        self.storageProvider = storageProvider
        self.expiresAt = expiresAt
        self.objectKey = objectKey
    }
}

protocol DiarizationAudioUploader {
    func upload(_ request: DiarizationUploadRequest) async throws -> DiarizationUploadResult
}

struct DiarizationTranscriptionRequest: Equatable {
    let chunk: DiarizationAudioChunk
    let remoteFileURL: URL
    let language: String
    let diarizationEnabled: Bool
    let speakerCount: Int?

    init(
        chunk: DiarizationAudioChunk,
        remoteFileURL: URL,
        language: String,
        diarizationEnabled: Bool,
        speakerCount: Int? = nil
    ) {
        self.chunk = chunk
        self.remoteFileURL = remoteFileURL
        self.language = language
        self.diarizationEnabled = diarizationEnabled
        self.speakerCount = speakerCount
    }
}

struct DiarizationProviderTask: Equatable {
    let provider: DiarizationProvider
    let taskID: String
    let chunkIndex: Int
    let state: DiarizationChunkState
    let remoteFileURL: URL
}

protocol DiarizationTranscriptionProvider {
    func submit(_ request: DiarizationTranscriptionRequest) async throws -> DiarizationProviderTask
    func waitForResult(task: DiarizationProviderTask, chunk: DiarizationAudioChunk) async throws -> DiarizationChunkResult
}
