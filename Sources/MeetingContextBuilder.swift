import Foundation

struct MeetingContextSnapshot {
    let promptText: String
    let hotEntryCount: Int
    let recentEntryCount: Int
    let durableMemoryItemCount: Int
    let promptLength: Int
}

enum MeetingContextBuilder {
    private static let hotWindow: TimeInterval = 10 * 60
    private static let recentWindow: TimeInterval = 30 * 60
    private static let hotBudget = 2800
    private static let recentBudget = 1800
    private static let durableBudget = 1400
    private static let latestAIBudget = 320

    static func buildSnapshot(
        transcriptEntries: [TranscriptEntry],
        insightCards: [InsightCard],
        now: Date = Date()
    ) -> MeetingContextSnapshot {
        let partition = partitionEntries(transcriptEntries, now: now)
        let durableMemory = buildDurableMemory(
            olderEntries: partition.older,
            insightCards: insightCards,
            now: now
        )
        let recentLines = buildTranscriptLines(
            entries: partition.recent.filter(\.isFinal),
            budget: recentBudget,
            includeStatus: false
        )
        let hotLines = buildTranscriptLines(
            entries: partition.hot,
            budget: hotBudget,
            includeStatus: true
        )

        var sections: [String] = []

        if let latestAIOutput = latestRelevantAIOutput(from: insightCards) {
            sections.append("【最近一次 AI 输出（避免重复）】\n\(latestAIOutput)")
        }

        if !durableMemory.isEmpty {
            sections.append("【长期记忆】\n" + durableMemory.joined(separator: "\n"))
        }

        if !recentLines.isEmpty {
            sections.append("【近期背景】\n" + recentLines.joined(separator: "\n"))
        }

        if !hotLines.isEmpty {
            sections.append("【最新讨论】\n" + hotLines.joined(separator: "\n"))
        }

        sections.append(
            "请优先根据【最新讨论】判断是否值得发言；【近期背景】用于理解上下文；【长期记忆】仅作参考，不要重复已经说过的结论。"
        )

        let promptText = sections.joined(separator: "\n\n")
        return MeetingContextSnapshot(
            promptText: promptText,
            hotEntryCount: partition.hot.count,
            recentEntryCount: partition.recent.count,
            durableMemoryItemCount: durableMemory.count,
            promptLength: promptText.count
        )
    }

    private static func partitionEntries(
        _ entries: [TranscriptEntry],
        now: Date
    ) -> (older: [TranscriptEntry], recent: [TranscriptEntry], hot: [TranscriptEntry]) {
        var older: [TranscriptEntry] = []
        var recent: [TranscriptEntry] = []
        var hot: [TranscriptEntry] = []

        for entry in entries {
            if entry.timestamp == .distantPast {
                older.append(entry)
                continue
            }

            let age = now.timeIntervalSince(entry.timestamp)
            if age <= hotWindow {
                hot.append(entry)
            } else if age <= recentWindow {
                recent.append(entry)
            } else {
                older.append(entry)
            }
        }

        return (older, recent, hot)
    }

    private static func buildDurableMemory(
        olderEntries: [TranscriptEntry],
        insightCards: [InsightCard],
        now: Date
    ) -> [String] {
        var lines: [String] = []
        var usedBudget = 0

        let durableCards = insightCards.filter { card in
            if card.kind == .system {
                return false
            }

            if card.isPinned || card.kind == .summary {
                return true
            }

            let age = now.timeIntervalSince(card.timestamp)
            return age > hotWindow && card.kind == .summary
        }

        for card in durableCards.suffix(4) {
            let prefix = card.isPinned ? "📌" : "🧭"
            let line = "\(prefix) \(card.content.clamped(to: 220))"
            if usedBudget + line.count > durableBudget {
                break
            }
            lines.append(line)
            usedBudget += line.count
        }

        let olderFinalEntries = olderEntries.filter(\.isFinal)
        if lines.isEmpty && !olderFinalEntries.isEmpty {
            lines.append("更早讨论共 \(olderFinalEntries.count) 条转写，以下为代表片段：")
            usedBudget += lines[0].count

            for sample in sampledEntries(from: olderFinalEntries, limit: 4) {
                let line = "- [\(formatTime(sample.timestamp))] \(sample.text.clamped(to: 120))"
                if usedBudget + line.count > durableBudget {
                    break
                }
                lines.append(line)
                usedBudget += line.count
            }
        }

        return lines
    }

    private static func buildTranscriptLines(
        entries: [TranscriptEntry],
        budget: Int,
        includeStatus: Bool
    ) -> [String] {
        guard !entries.isEmpty else { return [] }

        var selected: [String] = []
        var usedBudget = 0

        for entry in entries.reversed() {
            let status = includeStatus ? (entry.isFinal ? "" : "[临时] ") : ""
            let line = "- [\(formatTime(entry.timestamp))] \(status)\(entry.text.clamped(to: includeStatus ? 220 : 180))"
            if usedBudget + line.count > budget {
                break
            }
            selected.append(line)
            usedBudget += line.count
        }

        return selected.reversed()
    }

    private static func sampledEntries(from entries: [TranscriptEntry], limit: Int) -> [TranscriptEntry] {
        guard entries.count > limit else {
            return entries
        }

        let step = Double(entries.count - 1) / Double(limit - 1)
        let indexes = (0..<limit).map { Int((Double($0) * step).rounded()) }
        return indexes.map { entries[$0] }
    }

    private static func latestRelevantAIOutput(from insightCards: [InsightCard]) -> String? {
        guard let card = insightCards.last(where: { $0.kind != .system }) else {
            return nil
        }

        return card.content.clamped(to: latestAIBudget)
    }

    private static func formatTime(_ date: Date) -> String {
        if date == .distantPast {
            return "早期"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private extension String {
    func clamped(to limit: Int) -> String {
        guard count > limit, limit > 1 else { return self }
        let endIndex = index(startIndex, offsetBy: max(limit - 1, 0))
        return String(self[..<endIndex]) + "…"
    }
}
