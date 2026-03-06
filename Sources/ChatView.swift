import SwiftUI
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ChatView")

struct ChatView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header with ⚡ 立即分析 button
            HStack {
                Text("🤖 AI 助手")
                    .font(.headline)

                Spacer()

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
            }
            .padding()

            Divider()

            // Chat messages
            if viewModel.chatMessages.isEmpty {
                VStack {
                    Spacer()
                    Text("AI 分析结果将在此显示")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.chatMessages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.chatMessages.count) {
                        if let last = viewModel.chatMessages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 8) {
                TextField("在此输入指令...", text: $viewModel.userInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
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
            }
            .padding()
            .onAppear {
                logger.info("ChatView appeared, setting input focus")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isInputFocused = true
                }
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(roleColor)

                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(message.content)
                .textSelection(.enabled)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(roleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var roleLabel: String {
        switch message.role {
        case .system: "系统"
        case .user: "用户"
        case .assistant: "AI"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .system: .secondary
        case .user: .blue
        case .assistant: .green
        }
    }

    private var roleBackground: Color {
        switch message.role {
        case .system: .gray.opacity(0.1)
        case .user: .blue.opacity(0.1)
        case .assistant: .green.opacity(0.1)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
