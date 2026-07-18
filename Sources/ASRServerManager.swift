import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ASRServer")

class ASRServerManager: ObservableObject {
    @Published var isRunning = false

    private var process: Process?
    private let port: Int
    private let apiKey: String

    private var goProjectDir: String {
        let sourceFile = URL(fileURLWithPath: #file)
        return sourceFile.deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()                // project root
            .appendingPathComponent("asr-bridge")
            .path
    }

    init(port: Int = 18089, apiKey: String) {
        self.port = port
        self.apiKey = apiKey
    }

    func start() async throws {
        let binaryPath = "\(goProjectDir)/bin/asr-bridge"

        // Build if needed
        if !FileManager.default.fileExists(atPath: binaryPath) {
            logger.info("Binary not found at \(binaryPath), building...")
            try await buildBinary(outputPath: binaryPath)
            logger.info("Build completed")
        } else {
            logger.info("Using existing binary: \(binaryPath)")
        }

        // 端口被占时：本项目残留 bridge 先清理，外来进程则直接报错（不误杀）
        try await clearStalePortListeners(expectedBinaryPath: binaryPath)

        // Start process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = []

        var env = ProcessInfo.processInfo.environment
        env["DASHSCOPE_API_KEY"] = apiKey
        env["ASR_BRIDGE_PORT"] = String(port)
        // DashScope 直连，绕开本机代理的长连接闲置超时（Go 的 dialer 读取 NO_PROXY/no_proxy）
        let noProxy = ASRBridgePortGuard.noProxyValue(merging: env["NO_PROXY"] ?? env["no_proxy"])
        env["NO_PROXY"] = noProxy
        env["no_proxy"] = noProxy
        proc.environment = env

        // 将 Go 子进程的 stderr 转发到 os.log
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") {
                logger.info("[bridge] \(l)")
            }
        }

        logger.info("Launching asr-bridge on :\(self.port)")
        try proc.run()
        self.process = proc

        // Wait for health check (max 15 seconds)
        for i in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            switch await probeHealth() {
            case .healthy:
                logger.info("Health check passed after \(Double(i+1) * 0.5)s")
                await MainActor.run { self.isRunning = true }
                return
            case .foreignService:
                // 端口上有人应答但不是本项目 bridge（同源衍生服务健康检查会假绿，必须按占用处理）
                logger.error("Health endpoint on port \(self.port) answered by a foreign service")
                proc.terminate()
                throw ServerError.portOccupied("ASR 端口 \(port) 的健康检查由其他服务应答（不是本项目 bridge）。请检查端口占用后重试。")
            case .unreachable:
                continue
            }
        }
        logger.error("Health check timeout after 15s")
        proc.terminate()
        throw ServerError.startupTimeout
    }

    private func clearStalePortListeners(expectedBinaryPath: String) async throws {
        let listeners = portListeners()
        switch ASRBridgePortGuard.action(listeners: listeners, expectedBinaryPath: expectedBinaryPath) {
        case .proceed:
            return
        case .abort(let reason):
            logger.error("Port \(self.port) occupied by foreign process: \(reason)")
            throw ServerError.portOccupied(reason)
        case .terminateStale(let pids):
            logger.warning("Terminating stale asr-bridge processes on port \(self.port): \(pids)")
            for pid in pids {
                kill(pid, SIGTERM)
            }
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if portListeners().isEmpty {
                    logger.info("Stale asr-bridge processes exited, port \(self.port) is free")
                    return
                }
            }
            throw ServerError.portOccupied("旧 asr-bridge 进程未能在 2 秒内退出（pids: \(pids)）")
        }
    }

    private func portListeners() -> [ASRBridgePortGuard.Listener] {
        guard let output = runCommand("/usr/sbin/lsof", ["-nP", "-ti", "tcp:\(port)", "-sTCP:LISTEN"]) else {
            return []
        }
        let pids = output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return pids.compactMap { pid in
            guard let path = runCommand("/bin/ps", ["-o", "comm=", "-p", "\(pid)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return nil
            }
            return ASRBridgePortGuard.Listener(pid: pid, executablePath: path)
        }
    }

    private func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.warning("runCommand failed to launch \(launchPath): \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
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
        buildProcess.arguments = ["build", "-o", outputPath, "."]
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

    private enum HealthProbe {
        case healthy
        case foreignService
        case unreachable
    }

    private func probeHealth() async -> HealthProbe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return .unreachable }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .unreachable }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["service"] as? String == "meetingai-asr-bridge" ? .healthy : .foreignService
        } catch {
            return .unreachable
        }
    }

    func stop() {
        logger.info("Stopping asr-bridge")
        if let proc = process {
            // 停止 stderr pipe 读取
            (proc.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            proc.terminate()
            proc.waitUntilExit()
        }
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
        case portOccupied(String)

        var errorDescription: String? {
            switch self {
            case .goNotFound: return "未找到 Go 编译器（检查 /opt/homebrew/bin/go 等路径）"
            case .buildFailed: return "asr-bridge 编译失败"
            case .startupTimeout: return "asr-bridge 启动超时（15秒内未通过健康检查）"
            case .portOccupied(let reason): return reason
            }
        }
    }
}
