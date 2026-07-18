import Foundation

enum DiarizationSessionGateSmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct DiarizationSessionGateSmoke {
    static func main() {
        do {
            try testNewSessionRejectsOlderToken()
            print("Diarization session gate smoke tests PASS")
        } catch {
            fputs("Diarization session gate smoke tests FAIL: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw DiarizationSessionGateSmokeFailure.failed(message)
        }
    }

    private static func testNewSessionRejectsOlderToken() throws {
        var gate = DiarizationSessionGate()
        let first = gate.beginNewSession()
        try expect(gate.accepts(first), "first session token should be accepted")

        let second = gate.beginNewSession()
        try expect(gate.accepts(second), "current session token should be accepted")
        try expect(!gate.accepts(first), "previous session token should be rejected")
    }
}
