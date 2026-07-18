import SwiftUI
import AppKit

@main
struct MeetingAIApp: App {
    @StateObject private var viewModel = MeetingViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("会议 AI 助手")
                    .font(.headline)
                    .accessibilityIdentifier("meeting-title")

                Spacer()

                if viewModel.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("录音中")
                            .accessibilityIdentifier("recording-status-label")
                        Text(formatDuration(viewModel.recordingDuration))
                            .monospacedDigit()
                            .accessibilityIdentifier("recording-duration-label")
                    }
                    .foregroundStyle(.secondary)

                    // Import transcript button (visible during recording)
                    Button {
                        viewModel.importTranscript()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入历史")
                    }
                    .help("导入历史转写文件")
                    .accessibilityLabel("导入历史")
                    .accessibilityIdentifier("import-transcript-button")
                }

                // AI Mode picker
                Picker("模式", selection: $viewModel.aiMode) {
                    ForEach(AIMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityIdentifier("ai-mode-picker")

                // Settings button
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Prompt 设置")
                .accessibilityLabel("设置")
                .accessibilityIdentifier("settings-button")

                Button(viewModel.isRecording ? "结束会议" : "开始会议") {
                    if viewModel.isRecording {
                        viewModel.stopMeeting()
                    } else {
                        Task { await viewModel.startMeeting() }
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isRecording ? .red : .accentColor)
                .accessibilityIdentifier("meeting-toggle-button")
            }
            .padding()

            Divider()

            HSplitView {
                TranscriptView()
                    .frame(minWidth: 300, idealWidth: 500)

                InsightFeedView()
                    .frame(minWidth: 400, idealWidth: 700)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
