import Foundation

struct AppConfig {
    let asrServerPort: Int
    let asrLanguage: String
    let autoAnalysisInterval: TimeInterval
    let aiModel: String
    let maxContextTokens: Int
    let dashscopeAPIKey: String
    let minimaxAPIKey: String
    let minimaxBaseURL: String

    static func load() -> AppConfig {
        let envVars = loadEnvFile()
        let jsonConfig = loadJSONConfig()

        return AppConfig(
            asrServerPort: jsonConfig["asr"]?["serverPort"] as? Int ?? 18080,
            asrLanguage: jsonConfig["asr"]?["language"] as? String ?? "zh",
            autoAnalysisInterval: TimeInterval(jsonConfig["ai"]?["autoAnalysisIntervalSeconds"] as? Int ?? 300),
            aiModel: jsonConfig["ai"]?["model"] as? String ?? "MiniMax-M2.5",
            maxContextTokens: jsonConfig["ai"]?["maxContextTokens"] as? Int ?? 100000,
            dashscopeAPIKey: envVars["DASHSCOPE_API_KEY"] ?? "",
            minimaxAPIKey: envVars["MINIMAX_API_KEY"] ?? "",
            minimaxBaseURL: jsonConfig["ai"]?["baseURL"] as? String ?? "https://api.minimaxi.com/v1/text/chatcompletion_v2"
        )
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
                envVars[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
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
