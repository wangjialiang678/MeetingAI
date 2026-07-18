import Foundation

/// 转写结果停摆看门狗。
/// 覆盖"有心跳没结果"的服务端静默降级（2026-07-18 19:41 场：DashScope 持续回执
/// input_audio_buffer.committed 但 19 分钟零识别结果，无错误帧，读超时/重连均不触发）。
/// 判定为停摆时轮换 ASR 流（bridge 存活，重连即建立新的上游会话）。
struct ASRResultsWatchdog {
    let stallThresholdSeconds: TimeInterval
    let cooldownSeconds: TimeInterval

    static let standard = ASRResultsWatchdog(stallThresholdSeconds: 180, cooldownSeconds: 180)

    /// - Parameters:
    ///   - lastTranscriptAt: 最近一次收到转写的时间（`.distantPast` 表示本场尚未收到）
    ///   - meetingStartAt: 会议开始时间（覆盖"开场即停摆"的情况）
    ///   - lastRotateAt: 上次看门狗轮换时间（冷却期内不重复轮换）
    func shouldRotate(
        now: Date,
        isRecording: Bool,
        lastTranscriptAt: Date,
        meetingStartAt: Date?,
        lastRotateAt: Date?
    ) -> Bool {
        guard isRecording, let meetingStartAt else { return false }
        let baseline = max(lastTranscriptAt, meetingStartAt)
        guard now.timeIntervalSince(baseline) >= stallThresholdSeconds else { return false }
        if let lastRotateAt, now.timeIntervalSince(lastRotateAt) < cooldownSeconds {
            return false
        }
        return true
    }
}
