import SwiftUI
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "InsightFeedView")

struct InsightFeedView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @FocusState private var isInputFocused: Bool
    @AppStorage("analysisBackend") private var analysisBackendRaw: String = AnalysisBackendMode.hybrid.rawValue

    private var selectedBackend: AnalysisBackendMode {
        AnalysisBackendMode(rawValue: analysisBackendRaw) ?? .hybrid
    }

    private var statusColor: Color {
        if viewModel.analysisActivityText != nil {
            return .blue
        }
        if viewModel.lastAnalysisStatusText.contains("最近失败") {
            return .red
        }
        if viewModel.lastAnalysisStatusText.contains("回退") {
            return .orange
        }
        return .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI 洞察")
                    .font(.headline)
                    .accessibilityIdentifier("insight-feed-title")
                Spacer()
                Text("\(viewModel.insightCards.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("insight-card-count")
                if viewModel.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("分析中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    viewModel.triggerAnalysis()
                } label: {
                    Label("立即分析", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!viewModel.isRecording || viewModel.isAnalyzing)
                .accessibilityIdentifier("analysis-trigger-button")
            }
            .padding()

            HStack(spacing: 8) {
                Text("后端：\(selectedBackend.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let activity = viewModel.analysisActivityText {
                    Text(activity)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .accessibilityIdentifier("analysis-activity-text")
                } else {
                    Text(viewModel.lastAnalysisStatusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("analysis-status-text")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            if viewModel.insightCards.isEmpty {
                VStack {
                    Spacer()
                    Text("AI 洞察将在此显示")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("insight-empty-state")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(viewModel.insightCards.enumerated()), id: \.element.id) { index, card in
                                InsightCardView(card: binding(for: index))
                                    .id(card.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.insightCards.count) {
                        if let last = viewModel.insightCards.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("向 AI 提问...", text: $viewModel.userInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .accessibilityIdentifier("insight-question-input")
                    .onSubmit {
                        viewModel.sendUserMessage()
                        isInputFocused = true
                    }
                Button("发送") {
                    viewModel.sendUserMessage()
                    isInputFocused = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.userInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("insight-send-button")
            }
            .padding()
            .onAppear {
                logger.info("InsightFeedView appeared, setting input focus")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isInputFocused = true
                }
            }
        }
    }

    private func binding(for index: Int) -> Binding<InsightCard> {
        Binding(
            get: { viewModel.insightCards[index] },
            set: { viewModel.insightCards[index] = $0 }
        )
    }
}

struct InsightCardView: View {
    @Binding var card: InsightCard

    private var isOldAndUnpinned: Bool {
        !card.isPinned && Date().timeIntervalSince(card.timestamp) > 900
    }

    var body: some View {
        if isOldAndUnpinned {
            HStack {
                Image(systemName: kindIcon)
                    .foregroundStyle(kindColor)
                    .font(.caption)
                Text(card.content.prefix(60) + (card.content.count > 60 ? "..." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(formatTime(card.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if card.kind == .summary {
                    HStack {
                        Rectangle()
                            .fill(Color.orange.opacity(0.6))
                            .frame(height: 1)
                        Text("阶段小结")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                        Rectangle()
                            .fill(Color.orange.opacity(0.6))
                            .frame(height: 1)
                    }
                }

                if card.kind == .reply, let query = card.userQuery {
                    Text("你问: \(query)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack(spacing: 6) {
                    Image(systemName: kindIcon)
                        .foregroundStyle(kindColor)
                    Text(kindLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(kindColor)
                    if let execution = card.execution {
                        Text(execution.backendBadgeText)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(execution.usedBackend == .codexCLI ? Color.blue.opacity(0.12) : Color.gray.opacity(0.12))
                            .clipShape(Capsule())
                            .accessibilityIdentifier("insight-card-backend-badge")
                    }
                    Text(formatTime(card.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        card.isPinned.toggle()
                    } label: {
                        Image(systemName: card.isPinned ? "pin.fill" : "pin")
                            .font(.caption)
                            .foregroundStyle(card.isPinned ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(card.isPinned ? "取消标记" : "标记重要")
                }

                Text(card.content)
                    .textSelection(.enabled)
                    .font(.body)
                    .accessibilityLabel(card.content)

                if let execution = card.execution {
                    Text(execution.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("insight-card-status")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(kindBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insight-card")
        }
    }

    private var kindIcon: String {
        switch card.kind {
        case .insight: return "lightbulb"
        case .reply: return "bubble.left"
        case .summary: return "list.clipboard"
        case .system: return "gearshape"
        }
    }

    private var kindLabel: String {
        switch card.kind {
        case .insight: return "洞察"
        case .reply: return "回复"
        case .summary: return "小结"
        case .system: return "系统"
        }
    }

    private var kindColor: Color {
        switch card.kind {
        case .insight: return .green
        case .reply: return .blue
        case .summary: return .orange
        case .system: return .gray
        }
    }

    private var kindBackground: Color {
        switch card.kind {
        case .insight: return .green.opacity(0.08)
        case .reply: return .blue.opacity(0.08)
        case .summary: return .orange.opacity(0.08)
        case .system: return .gray.opacity(0.06)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
