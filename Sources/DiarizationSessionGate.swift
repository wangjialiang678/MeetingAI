import Foundation

struct DiarizationSessionGate {
    private(set) var currentGeneration: Int = 0

    mutating func beginNewSession() -> Int {
        currentGeneration += 1
        return currentGeneration
    }

    func accepts(_ generation: Int) -> Bool {
        generation == currentGeneration
    }
}
