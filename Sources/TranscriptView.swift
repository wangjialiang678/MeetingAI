import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("📝 实时转写")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.transcriptEntries.filter(\.isFinal).count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if viewModel.transcriptEntries.isEmpty {
                VStack {
                    Spacer()
                    Text("等待录音开始...")
                        .foregroundStyle(.secondary)
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
}
