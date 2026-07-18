import Foundation

enum ASRStaleBridgePolicySmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct ASRStaleBridgePolicySmoke {
    static let expectedPath = "/Users/tester/projects/meetingai/asr-bridge/bin/asr-bridge"

    static func main() {
        do {
            try testFreePortProceeds()
            try testOwnStaleBridgeIsTerminated()
            try testForeignProcessAborts()
            try testMixedListenersAbortWithoutKilling()
            try testAbortMessageSanitizesHomePath()
            print("ASR stale bridge policy smoke tests PASS")
        } catch {
            fputs("ASR stale bridge policy smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw ASRStaleBridgePolicySmokeFailure.failed(message)
        }
    }

    private static func testFreePortProceeds() throws {
        let action = ASRBridgePortGuard.action(listeners: [], expectedBinaryPath: expectedPath)
        try expect(action == .proceed, "free port should proceed")
    }

    private static func testOwnStaleBridgeIsTerminated() throws {
        let action = ASRBridgePortGuard.action(
            listeners: [
                ASRBridgePortGuard.Listener(pid: 111, executablePath: expectedPath),
                ASRBridgePortGuard.Listener(pid: 222, executablePath: expectedPath)
            ],
            expectedBinaryPath: expectedPath
        )
        try expect(action == .terminateStale([111, 222]), "stale own bridge processes should be terminated, got \(action)")
    }

    private static func testForeignProcessAborts() throws {
        let action = ASRBridgePortGuard.action(
            listeners: [
                ASRBridgePortGuard.Listener(pid: 333, executablePath: "/Applications/SpeakLow.app/Contents/MacOS/asr-bridge")
            ],
            expectedBinaryPath: expectedPath
        )
        guard case .abort(let reason) = action else {
            throw ASRStaleBridgePolicySmokeFailure.failed("foreign listener should abort, got \(action)")
        }
        try expect(reason.contains("SpeakLow"), "abort reason should name the foreign process, got: \(reason)")
        try expect(reason.contains("333"), "abort reason should include the pid, got: \(reason)")
    }

    private static func testMixedListenersAbortWithoutKilling() throws {
        let action = ASRBridgePortGuard.action(
            listeners: [
                ASRBridgePortGuard.Listener(pid: 111, executablePath: expectedPath),
                ASRBridgePortGuard.Listener(pid: 333, executablePath: "/usr/local/bin/other-server")
            ],
            expectedBinaryPath: expectedPath
        )
        guard case .abort = action else {
            throw ASRStaleBridgePolicySmokeFailure.failed("mixed listeners must abort instead of killing, got \(action)")
        }
    }

    private static func testAbortMessageSanitizesHomePath() throws {
        let foreignInHome = NSHomeDirectory() + "/some-tool/bin/asr-bridge"
        let action = ASRBridgePortGuard.action(
            listeners: [ASRBridgePortGuard.Listener(pid: 444, executablePath: foreignInHome)],
            expectedBinaryPath: expectedPath
        )
        guard case .abort(let reason) = action else {
            throw ASRStaleBridgePolicySmokeFailure.failed("foreign listener should abort, got \(action)")
        }
        try expect(!reason.contains(NSHomeDirectory()), "abort reason must not leak absolute home path, got: \(reason)")
        try expect(reason.contains("~/some-tool/bin/asr-bridge"), "abort reason should keep a readable sanitized path, got: \(reason)")
    }
}
