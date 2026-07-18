import Foundation

/// asr-bridge 启动前的端口占用决策。
/// 只允许终止"本项目自己的 bridge 残留进程"；端口上有任何外来进程（例如 SpeakLow 的同名 bridge）
/// 一律中止启动并给出可读原因，绝不代替用户杀别人的进程。
enum ASRBridgePortGuard {
    struct Listener: Equatable {
        let pid: Int32
        let executablePath: String
    }

    enum Action: Equatable {
        case proceed
        case terminateStale([Int32])
        case abort(String)
    }

    static func action(listeners: [Listener], expectedBinaryPath: String) -> Action {
        guard !listeners.isEmpty else { return .proceed }

        let foreign = listeners.filter { $0.executablePath != expectedBinaryPath }
        guard foreign.isEmpty else {
            let described = foreign
                .map { "\(sanitizePath($0.executablePath)) (pid \($0.pid))" }
                .joined(separator: ", ")
            return .abort("ASR 端口被其他进程占用：\(described)。请先退出该进程或修改 asr.serverPort 配置。")
        }

        return .terminateStale(listeners.map(\.pid))
    }

    private static func sanitizePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// bridge 子进程的 NO_PROXY 值：本机 Clash 类代理会闲置超时/重置 bridge→DashScope 长连接
    /// （2026-07-18 真实会议每 30-90 秒一次 reset），DashScope 必须直连。保留调用方已有的 NO_PROXY 条目。
    static func noProxyValue(merging existing: String?) -> String {
        let dashscopeHost = "dashscope.aliyuncs.com"
        let entries = (existing ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.contains(dashscopeHost) else {
            return entries.joined(separator: ",")
        }
        return (entries + [dashscopeHost]).joined(separator: ",")
    }
}
