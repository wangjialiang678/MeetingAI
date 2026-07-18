import Foundation

struct AppConfig {
    let asrServerPort: Int
    let asrLanguage: String
    let autoAnalysisInterval: TimeInterval
    let aiModel: String
    let maxContextTokens: Int
    let dashscopeAPIKey: String
    let aiAPIKey: String
    let aiBaseURL: String
    let uiFixtureMode: Bool
    let sessionsDirectory: URL
    let segmentedDiarizationEnabled: Bool
    let diarizationChunkDurationSeconds: TimeInterval
    let diarizationProvider: String
    let diarizationUploadStorage: String
    let diarizationUploadRegion: String
    let diarizationUploadEndpoint: String
    let diarizationUploadBucket: String
    let diarizationObjectPrefix: String
    let diarizationPresignTTLSeconds: TimeInterval
    let diarizationFunASRBaseURL: String
    let diarizationPollIntervalSeconds: TimeInterval
    let diarizationPollTimeoutSeconds: TimeInterval
    let diarizationSpeakerCount: Int?
    let ossAccessKeyID: String
    let ossAccessKeySecret: String
    let ossSessionToken: String

    static func load() -> AppConfig {
        let processEnv = ProcessInfo.processInfo.environment
        let envVars = loadEnvFile()
        let jsonConfig = loadJSONConfig()
        let sessionsDirectory: URL
        let diarizationConfig = jsonConfig["diarization"]
        func env(_ key: String) -> String? {
            processEnv[key] ?? envVars[key]
        }

        if let overridePath = env("MEETINGAI_SESSIONS_DIR"), !overridePath.isEmpty {
            sessionsDirectory = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            sessionsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingAI/sessions", isDirectory: true)
        }

        return AppConfig(
            asrServerPort: jsonConfig["asr"]?["serverPort"] as? Int ?? 18089,
            asrLanguage: jsonConfig["asr"]?["language"] as? String ?? "zh",
            autoAnalysisInterval: TimeInterval(jsonConfig["ai"]?["autoAnalysisIntervalSeconds"] as? Int ?? 300),
            aiModel: jsonConfig["ai"]?["model"] as? String ?? "qwen/qwen3.5-122b-a10b",
            maxContextTokens: jsonConfig["ai"]?["maxContextTokens"] as? Int ?? 100000,
            dashscopeAPIKey: env("DASHSCOPE_API_KEY") ?? "",
            aiAPIKey: env(jsonConfig["ai"]?["apiKeyEnv"] as? String ?? "QWEN_API_KEY") ?? "",
            aiBaseURL: jsonConfig["ai"]?["baseURL"] as? String ?? "https://integrate.api.nvidia.com/v1/chat/completions",
            uiFixtureMode: boolFromEnv(env("MEETINGAI_UI_FIXTURE")),
            sessionsDirectory: sessionsDirectory,
            segmentedDiarizationEnabled: optionalBoolFromEnv(env("MEETINGAI_SEGMENTED_DIARIZATION"))
                ?? diarizationConfig?["enabled"] as? Bool
                ?? true,
            diarizationChunkDurationSeconds: positiveTimeIntervalFromEnv(env("MEETINGAI_DIARIZATION_CHUNK_SECONDS"))
                ?? numberAsTimeInterval(diarizationConfig?["chunkDurationSeconds"])
                ?? 60,
            diarizationProvider: env("MEETINGAI_DIARIZATION_PROVIDER")
                ?? diarizationConfig?["provider"] as? String
                ?? "dashscopeFunASR",
            diarizationUploadStorage: env("MEETINGAI_DIARIZATION_UPLOAD_STORAGE")
                ?? diarizationConfig?["uploadStorage"] as? String
                ?? "unconfigured",
            diarizationUploadRegion: env("MEETINGAI_DIARIZATION_UPLOAD_REGION")
                ?? diarizationConfig?["uploadRegion"] as? String
                ?? "cn-beijing",
            diarizationUploadEndpoint: env("MEETINGAI_DIARIZATION_UPLOAD_ENDPOINT")
                ?? diarizationConfig?["uploadEndpoint"] as? String
                ?? "https://oss-cn-beijing.aliyuncs.com",
            diarizationUploadBucket: env("MEETINGAI_DIARIZATION_UPLOAD_BUCKET")
                ?? diarizationConfig?["uploadBucket"] as? String
                ?? "",
            diarizationObjectPrefix: env("MEETINGAI_DIARIZATION_OBJECT_PREFIX")
                ?? diarizationConfig?["objectPrefix"] as? String
                ?? "meetingai/chunks",
            diarizationPresignTTLSeconds: positiveTimeIntervalFromEnv(env("MEETINGAI_DIARIZATION_PRESIGN_TTL_SECONDS"))
                ?? numberAsTimeInterval(diarizationConfig?["presignTTLSeconds"])
                ?? 6 * 60 * 60,
            diarizationFunASRBaseURL: env("MEETINGAI_DIARIZATION_FUNASR_BASE_URL")
                ?? diarizationConfig?["funASRBaseURL"] as? String
                ?? "https://dashscope.aliyuncs.com/api/v1",
            diarizationPollIntervalSeconds: positiveTimeIntervalFromEnv(env("MEETINGAI_DIARIZATION_POLL_INTERVAL_SECONDS"))
                ?? numberAsTimeInterval(diarizationConfig?["pollIntervalSeconds"])
                ?? 5,
            diarizationPollTimeoutSeconds: positiveTimeIntervalFromEnv(env("MEETINGAI_DIARIZATION_POLL_TIMEOUT_SECONDS"))
                ?? numberAsTimeInterval(diarizationConfig?["pollTimeoutSeconds"])
                ?? 600,
            diarizationSpeakerCount: validSpeakerCount(
                positiveIntFromEnv(env("MEETINGAI_DIARIZATION_SPEAKER_COUNT"))
                    ?? diarizationConfig?["speakerCount"] as? Int
            ),
            ossAccessKeyID: env("OSS_ACCESS_KEY_ID") ?? "",
            ossAccessKeySecret: env("OSS_ACCESS_KEY_SECRET") ?? "",
            ossSessionToken: env("OSS_SESSION_TOKEN") ?? ""
        )
    }

    private static func boolFromEnv(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func optionalBoolFromEnv(_ value: String?) -> Bool? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func positiveTimeIntervalFromEnv(_ value: String?) -> TimeInterval? {
        guard let value, let parsed = Double(value), parsed > 0 else { return nil }
        return parsed
    }

    private static func positiveIntFromEnv(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value), parsed > 0 else { return nil }
        return parsed
    }

    private static func validSpeakerCount(_ value: Int?) -> Int? {
        guard let value, (2...100).contains(value) else { return nil }
        return value
    }

    private static func numberAsTimeInterval(_ value: Any?) -> TimeInterval? {
        switch value {
        case let value as Double where value > 0:
            return value
        case let value as Int where value > 0:
            return TimeInterval(value)
        default:
            return nil
        }
    }

    private static func loadEnvFile() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let vaultURL = home.appendingPathComponent(".claude/api-vault.env")
        var envVars: [String: String] = [:]

        guard let content = try? String(contentsOf: vaultURL, encoding: .utf8) else { return envVars }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                // shell 风格引号包裹的值要剥壳（TokenHub key 带引号导致 401 的教训）
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                envVars[String(parts[0]).trimmingCharacters(in: .whitespaces)] = value
            }
        }
        return envVars
    }

    private static func loadJSONConfig() -> [String: [String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent("Library/Application Support/MeetingAI/config.json")

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        return json
    }
}
