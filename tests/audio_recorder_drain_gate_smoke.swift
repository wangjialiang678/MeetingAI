import Foundation

enum AudioRecorderDrainGateSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct AudioRecorderDrainGateSmoke {
    static func main() {
        do {
            try testWaitForIdleBlocksUntilCallbackFinishes()
            try testWaitForIdleReturnsImmediatelyWhenIdle()
            try testWaitForIdleTimesOutWhenCallbackHangs()
            print("Audio recorder drain gate smoke tests PASS")
        } catch {
            fputs("Audio recorder drain gate smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw AudioRecorderDrainGateSmokeFailure.failed(message)
        }
    }

    private static func testWaitForIdleBlocksUntilCallbackFinishes() throws {
        let gate = AudioTapDrainGate()
        let started = DispatchSemaphore(value: 0)
        let workFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            gate.perform {
                started.signal()
                Thread.sleep(forTimeInterval: 0.15)
                workFinished.signal()
            }
        }

        try expect(started.wait(timeout: .now() + 1) == .success, "callback should start")
        let begin = Date()
        gate.waitForIdle()
        let elapsed = Date().timeIntervalSince(begin)

        try expect(workFinished.wait(timeout: .now()) == .success, "waitForIdle should wait for callback work completion")
        try expect(elapsed >= 0.10, "waitForIdle should block while callback is active")
    }

    private static func testWaitForIdleReturnsImmediatelyWhenIdle() throws {
        let gate = AudioTapDrainGate()
        let begin = Date()
        gate.waitForIdle()
        try expect(Date().timeIntervalSince(begin) < 0.05, "waitForIdle should return quickly when idle")
    }

    private static func testWaitForIdleTimesOutWhenCallbackHangs() throws {
        let gate = AudioTapDrainGate()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            gate.perform {
                started.signal()
                release.wait()
            }
        }

        try expect(started.wait(timeout: .now() + 1) == .success, "callback should start")
        let begin = Date()
        let drained = gate.waitForIdle(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(begin)
        release.signal()

        try expect(drained == false, "waitForIdle should report timeout when a callback hangs")
        try expect(elapsed >= 0.15 && elapsed < 1.0, "waitForIdle timeout should bound the wait, got \(elapsed)s")
    }
}
