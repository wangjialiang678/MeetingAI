import Foundation

enum WatchdogSmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct ASRResultsWatchdogSmoke {
    static func main() {
        do {
            let wd = ASRResultsWatchdog(stallThresholdSeconds: 180, cooldownSeconds: 180)
            let t0 = Date(timeIntervalSince1970: 1_000_000)

            func expect(_ condition: Bool, _ message: String) throws {
                if !condition { throw WatchdogSmokeFailure.failed(message) }
            }

            // 未录音不轮换
            try expect(!wd.shouldRotate(now: t0.addingTimeInterval(999), isRecording: false, lastTranscriptAt: t0, meetingStartAt: t0, lastRotateAt: nil), "not recording must not rotate")
            // 停摆未达阈值不轮换
            try expect(!wd.shouldRotate(now: t0.addingTimeInterval(179), isRecording: true, lastTranscriptAt: t0, meetingStartAt: t0, lastRotateAt: nil), "179s stall must not rotate")
            // 达阈值轮换
            try expect(wd.shouldRotate(now: t0.addingTimeInterval(180), isRecording: true, lastTranscriptAt: t0, meetingStartAt: t0, lastRotateAt: nil), "180s stall must rotate")
            // 开场即停摆（从未收到转写）也要轮换：以会议开始时间为基线
            try expect(wd.shouldRotate(now: t0.addingTimeInterval(180), isRecording: true, lastTranscriptAt: .distantPast, meetingStartAt: t0, lastRotateAt: nil), "start-stalled session must rotate from meeting start baseline")
            try expect(!wd.shouldRotate(now: t0.addingTimeInterval(60), isRecording: true, lastTranscriptAt: .distantPast, meetingStartAt: t0, lastRotateAt: nil), "fresh session within threshold must not rotate")
            // 无会议开始时间（未在会议中）不轮换
            try expect(!wd.shouldRotate(now: t0.addingTimeInterval(999), isRecording: true, lastTranscriptAt: t0, meetingStartAt: nil, lastRotateAt: nil), "missing meeting start must not rotate")
            // 冷却期内不重复轮换，冷却结束后可再次轮换
            let rotated = t0.addingTimeInterval(180)
            try expect(!wd.shouldRotate(now: rotated.addingTimeInterval(179), isRecording: true, lastTranscriptAt: t0, meetingStartAt: t0, lastRotateAt: rotated), "cooldown must block repeat rotation")
            try expect(wd.shouldRotate(now: rotated.addingTimeInterval(180), isRecording: true, lastTranscriptAt: t0, meetingStartAt: t0, lastRotateAt: rotated), "after cooldown rotation must resume")
            // 恢复后基线更新：有新转写则不轮换
            try expect(!wd.shouldRotate(now: rotated.addingTimeInterval(200), isRecording: true, lastTranscriptAt: rotated.addingTimeInterval(190), meetingStartAt: t0, lastRotateAt: rotated), "fresh transcript resets stall baseline")

            print("ASR results watchdog smoke tests PASS")
        } catch {
            fputs("ASR results watchdog smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
