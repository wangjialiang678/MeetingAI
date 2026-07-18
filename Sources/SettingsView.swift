import SwiftUI

struct SettingsView: View {
    @AppStorage("customSystemPrompt") private var customPrompt: String = ""
    @AppStorage("analysisBackend") private var analysisBackendRaw: String = AnalysisBackendMode.hybrid.rawValue
    @Environment(\.dismiss) private var dismiss

    private let defaultPromptPreview = MeetingViewModel.buildDefaultSystemPrompt(count: 1, elapsedMin: 5, mode: .advisor)

    private var selectedBackend: AnalysisBackendMode {
        get { AnalysisBackendMode(rawValue: analysisBackendRaw) ?? .hybrid }
        nonmutating set { analysisBackendRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("分析 Prompt 设置")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("分析后端")
                    .font(.headline)

                Picker("分析后端", selection: Binding(
                    get: { selectedBackend },
                    set: { selectedBackend = $0 }
                )) {
                    ForEach(AnalysisBackendMode.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedBackend.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("当前 Hybrid 策略：洞察优先走 Codex CLI，总结与追问回复走 HTTP。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            HSplitView {
                // Left: Custom prompt editor
                VStack(alignment: .leading, spacing: 8) {
                    Label("自定义 Prompt（留空则使用默认）", systemImage: "pencil")
                        .font(.headline)
                        .padding(.top, 12)

                    TextEditor(text: $customPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    HStack {
                        Button("重置为默认") {
                            customPrompt = ""
                        }
                        .foregroundStyle(.secondary)
                        Spacer()
                        Text(customPrompt.isEmpty ? "使用默认 Prompt" : "已启用自定义 Prompt")
                            .font(.caption)
                            .foregroundColor(customPrompt.isEmpty ? .secondary : .green)
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 16)
                .frame(minWidth: 280)

                // Right: Default prompt reference
                VStack(alignment: .leading, spacing: 8) {
                    Label("默认 Prompt（仅供参考）", systemImage: "doc.text")
                        .font(.headline)
                        .padding(.top, 12)

                    ScrollView {
                        Text(defaultPromptPreview)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 16)
                .frame(minWidth: 280)
            }
        }
        .frame(width: 700, height: 500)
    }
}
