import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ASRServer")

class ASRServerManager: ObservableObject {
    @Published var isRunning = false

    private var process: Process?
    private let port: Int
    private let apiKey: String

    private let goProjectDir = "/Users/michael/projects/组件模块/audio-asr-suite/go/audio-asr-go"

    init(port: Int = 18080, apiKey: String) {
        self.port = port
        self.apiKey = apiKey
    }

    func start() async throws {
        let binaryPath = "\(goProjectDir)/bin/asr-server"

        // Build if needed
        if !FileManager.default.fileExists(atPath: binaryPath) {
            logger.info("Binary not found at \(binaryPath), building...")
            try await buildBinary(outputPath: binaryPath)
            logger.info("Build completed")
        } else {
            logger.info("Using existing binary: \(binaryPath)")
        }

        // Start process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--listen", ":\(port)"]

        var env = ProcessInfo.processInfo.environment
        env["DASHSCOPE_API_KEY"] = apiKey
        proc.environment = env

        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        logger.info("Launching asr-server on :\(self.port)")
        try proc.run()
        self.process = proc

        // Wait for health check (max 15 seconds)
        for i in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if await isHealthy() {
                logger.info("Health check passed after \(Double(i+1) * 0.5)s")
                await MainActor.run { self.isRunning = true }
                return
            }
        }
        logger.error("Health check timeout after 15s")
        proc.terminate()
        throw ServerError.startupTimeout
    }

    private func buildBinary(outputPath: String) async throws {
        guard let goPath = findGoBinary() else {
            throw ServerError.goNotFound
        }

        // Create output directory
        let binDir = (outputPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: goPath)
        buildProcess.arguments = ["build", "-o", outputPath, "./cmd/asr-server"]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: goProjectDir)
        buildProcess.environment = ProcessInfo.processInfo.environment

        try buildProcess.run()
        buildProcess.waitUntilExit()

        guard buildProcess.terminationStatus == 0 else {
            throw ServerError.buildFailed
        }
    }

    private func findGoBinary() -> String? {
        let paths = [
            "/opt/homebrew/bin/go",
            "/usr/local/go/bin/go",
            "/usr/local/bin/go"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/healthz") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func stop() {
        logger.info("Stopping asr-server")
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        isRunning = false
    }

    deinit {
        stop()
    }

    enum ServerError: LocalizedError {
        case goNotFound
        case buildFailed
        case startupTimeout

        var errorDescription: String? {
            switch self {
            case .goNotFound: return "未找到 Go 编译器（检查 /opt/homebrew/bin/go 等路径）"
            case .buildFailed: return "asr-server 编译失败"
            case .startupTimeout: return "asr-server 启动超时（15秒内未通过健康检查）"
            }
        }
    }
}
