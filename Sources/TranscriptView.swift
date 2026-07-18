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
                Text("\(viewModel.transcriptEntries.filter(\.isFinal).count) 条")
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
                            ForEach(viewModel.transcriptEntries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(formatTime(entry.timestamp))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 65, alignment: .leading)

                                    Text(entry.text)
                                        .opacity(entry.isFinal ? 1.0 : 0.5)
                                        .italic(!entry.isFinal)
                                        .textSelection(.enabled)
                                }
                                .id(entry.id)
                            }

                            if !viewModel.speakerBackfillSegments.isEmpty {
                                Divider()
                                    .padding(.vertical, 6)

                                Text("说话人分离回填")
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
