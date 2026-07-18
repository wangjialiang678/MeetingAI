import Foundation

/// 轻量洞察重复度检测：字符 bigram Jaccard 相似度。
/// 目标是拦截"换了措辞但没有新信息"的自动洞察，宁可放过也不误杀，阈值偏保守。
enum InsightDeduplicator {
    static let defaultThreshold = 0.85
    static let defaultWindow = 3

    /// 与最近 window 条洞察逐一比较，返回达到阈值的最高相似度；无重复返回 nil。
    static func duplicateSimilarity(
        candidate: String,
        recentInsights: [String],
        threshold: Double = defaultThreshold,
        window: Int = defaultWindow
    ) -> Double? {
        let candidateGrams = bigrams(normalize(candidate))
        guard !candidateGrams.isEmpty else { return nil }

        var best: Double?
        for previous in recentInsights.suffix(window) {
            let similarity = jaccard(candidateGrams, bigrams(normalize(previous)))
            if similarity >= threshold && similarity > (best ?? 0) {
                best = similarity
            }
        }
        return best
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        jaccard(bigrams(normalize(a)), bigrams(normalize(b)))
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }.map(Character.init))
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count > 1 else {
            return characters.isEmpty ? [] : [String(characters[0])]
        }
        var grams = Set<String>()
        for index in 0..<(characters.count - 1) {
            grams.insert(String(characters[index]) + String(characters[index + 1]))
        }
        return grams
    }
}
