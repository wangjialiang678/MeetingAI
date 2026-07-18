import Foundation

struct DiarizationOSSUploadConfiguration: Equatable {
    let region: String
    let endpoint: String
    let bucket: String
    let objectPrefix: String
    let accessKeyID: String
    let accessKeySecret: String
    let sessionToken: String?
    let presignTTLSeconds: TimeInterval

    var isReady: Bool {
        missingConfigurationReason == nil
    }

    var missingConfigurationReason: String? {
        if region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "OSS region is not configured"
        }
        if normalizedEndpoint.isEmpty {
            return "OSS endpoint is not configured"
        }
        if bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "OSS bucket is not configured"
        }
        if accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "OSS credentials are not configured"
        }
        return nil
    }

    var normalizedEndpoint: String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host {
            return host
        }
        return trimmed
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedObjectPrefix: String {
        objectPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var clampedPresignTTLSeconds: TimeInterval {
        min(max(60, presignTTLSeconds), 7 * 24 * 60 * 60)
    }
}

enum DiarizationOSSObjectKeyBuilder {
    static func makeObjectKey(
        objectPrefix: String,
        sessionStem: String,
        chunk: DiarizationAudioChunk
    ) -> String {
        var parts: [String] = []
        let normalizedPrefix = objectPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !normalizedPrefix.isEmpty {
            parts.append(normalizedPrefix)
        }
        parts.append(sanitizePathComponent(sessionStem))
        parts.append(String(format: "%@-chunk-%04d.wav", sanitizePathComponent(sessionStem), chunk.index))
        return parts.joined(separator: "/")
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "session" : collapsed
    }
}
