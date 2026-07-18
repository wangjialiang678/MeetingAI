import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("📝 实时转写")
                    .font(.headline)
                    .accessibilityIdentifier("transcript-title")
                Spacer()
                Text(headerCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcript-count")
            }
            .padding()

            Divider()

            if viewModel.transcriptEntries.isEmpty && viewModel.speakerBackfillSegments.isEmpty {
                VStack {
                    Spacer()
                    Text("等待录音开始...")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("transcript-empty-state")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            // 已完成说话人分离+纠错的部分作为主体，滚动替代对应时间段的实时转写
                            if !viewModel.speakerBackfillSegments.isEmpty {
                                Text("说话人转写（已处理）")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("speaker-backfill-title")

                                ForEach(Array(viewModel.speakerBackfillSegments.enumerated()), id: \.offset) { _, segment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(formatMilliseconds(segment.beginMilliseconds))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 92, alignment: .leading)

                                        Text(segment.speakerID)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 74, alignment: .leading)

                                        Text(segment.text)
                                            .textSelection(.enabled)
                                    }
                                }

                                Divider()
                                    .padding(.vertical, 6)

                                Text("实时转写（最新，待分片处理）")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(realtimeTailEntries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(formatTime(entry.timestamp))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 65, alignment: .leading)

                                    Text(displayText(for: entry))
                                        .opacity(entry.isFinal ? 1.0 : 0.5)
                                        .italic(!entry.isFinal)
                                        .textSelection(.enabled)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.transcriptEntries.count) {
                        if let last = viewModel.transcriptEntries.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var headerCountText: String {
        let speakerCount = viewModel.speakerBackfillSegments.count
        if speakerCount > 0 {
            return "\(speakerCount) 句已处理 · \(viewModel.transcriptEntries.count) 段实时"
        }
        return "\(viewModel.transcriptEntries.count) 段"
    }

    /// 有说话人覆盖后：早于覆盖时间的 final 条目隐藏（已由说话人段落替代）；活跃 partial 保留为实时尾巴
    private var realtimeTailEntries: [TranscriptEntry] {
        guard !viewModel.speakerBackfillSegments.isEmpty,
              let cutoff = viewModel.speakerCoverageCutoffDate else {
            return viewModel.transcriptEntries
        }
        return viewModel.transcriptEntries.filter { !$0.isFinal || $0.timestamp > cutoff }
    }

    /// 活跃 partial 会累积整场文本；有说话人覆盖时只显示尾部，避免与说话人段落大面积重复
    private func displayText(for entry: TranscriptEntry) -> String {
        guard !viewModel.speakerBackfillSegments.isEmpty, !entry.isFinal, entry.text.count > 600 else {
            return entry.text
        }
        return "…" + entry.text.suffix(600)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatMilliseconds(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
