# 会议 AI 助手 (MeetingAI)

Mac 原生桌面应用，会议期间实时录音转写，AI 自动分析并给出建议，支持对话式交互。

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言/框架 | Swift 5.9 + SwiftUI，macOS 14+ |
| 构建工具 | Swift Package Manager (SPM)，executableTarget，无外部依赖 |
| 录音采集 | AVAudioEngine，16kHz PCM16 单声道 + MP3 文件录制 |
| ASR 后端 | asr-bridge（Go 子进程，:18089），JSON WebSocket，DashScope qwen3-asr-flash-realtime |
| LLM | MiniMax M2.5，HTTP API（OpenAI-compatible chat completions 格式） |
| 日志 | os.log（subsystem: "MeetingAI"，按模块分 category） |

## 目录结构

```
MeetingAI/
├── Package.swift               # SPM 配置，executableTarget，平台 macOS 14
├── PRD.md                      # 产品需求文档（含架构图、UI 设计、API 说明）
├── asr-bridge/                 # Go ASR 代理（从 speaklow 适配）
│   ├── main.go                 # HTTP 服务入口，/health + /v1/stream
│   ├── stream.go               # 核心流式 WebSocket ASR 代理（DashScope qwen3-asr）
│   ├── hotword.go              # 热词加载
│   ├── env.go                  # 环境变量加载（~/.claude/api-vault.env）
│   ├── go.mod                  # 模块 meetingai/asr-bridge
│   └── go.sum
├── Sources/
│   ├── ContentView.swift       # @main 入口，顶部栏 + HSplitView 双面板布局
│   ├── MeetingViewModel.swift  # 核心状态机，@MainActor ObservableObject
│   ├── Models.swift            # TranscriptEntry / ChatMessage 数据模型
│   ├── Config.swift            # AppConfig，从 api-vault.env 和 config.json 加载
│   ├── ASRServerManager.swift  # Go 子进程管理（自动编译/启动/健康检查/终止）
│   ├── ASRClient.swift         # JSON WebSocket 客户端，连接 asr-bridge
│   ├── AudioRecorder.swift     # AVAudioEngine 录音，双路输出 PCM16 + MP3
│   ├── AIEngine.swift          # MiniMax HTTP API 调用封装
│   ├── TranscriptView.swift    # 左侧实时转写面板（带时间戳，自动滚动）
│   ├── ChatView.swift          # 右侧 AI 对话面板
│   └── SettingsView.swift      # 设置界面（自定义 System Prompt 等）
└── .claude/
    └── memory-bank/            # 调研记录、会话日志
```

## 常用命令

```bash
# 构建（Debug）
swift build

# 运行（需要麦克风权限 + ~/.claude/api-vault.env 中的 API Key）
swift run MeetingAI

# 清理构建产物
swift package clean

# 查看可执行文件路径
swift build --show-bin-path

# 手动清理遗留的 asr-bridge 子进程（swift run 强制退出时可能遗留）
pkill asr-bridge
```

## 配置与密钥

**API 密钥**（从 `~/.claude/api-vault.env` 自动读取，格式 `KEY=VALUE`）：
```
DASHSCOPE_API_KEY=...   # ASR 服务（DashScope/阿里云）
MINIMAX_API_KEY=...     # AI 分析（MiniMax M2.5）
```

**应用配置**（`~/Library/Application Support/MeetingAI/config.json`，不存在则使用默认值）：
```json
{
  "asr": { "serverPort": 18089, "language": "zh" },
  "ai": {
    "autoAnalysisIntervalSeconds": 300,
    "model": "MiniMax-M2.5",
    "maxContextTokens": 100000,
    "baseURL": "https://api.minimaxi.com/v1/text/chatcompletion_v2"
  }
}
```

**会话数据**自动保存到 `~/Library/Application Support/MeetingAI/sessions/`：
- `yyyy-MM-dd-HH-mm-ss.txt`：转写文本（每条 `[HH:mm:ss] 文字` 格式）
- `yyyy-MM-dd-HH-mm-ss.mp3`：对应录音文件

## 数据流

```
麦克风 (AVAudioEngine) → AudioRecorder (PCM16) → ASRClient (JSON WebSocket)
                              ↓ MP3                      ↓ base64 audio
                         本地文件              asr-bridge (Go 子进程, :18089)
                                                         ↓ DashScope qwen3-asr-flash-realtime
                              MeetingViewModel ← handleTranscript()
                                    ↓ 触发分析
                              AIEngine → MiniMax HTTP API
                                    ↓
                              ChatMessage[] → ChatView
```

## AI 分析触发逻辑

三种自动触发（均在 `MeetingViewModel` 中，每 10 秒检查一次）：
1. **内容积累**：每新增 8 条 final 转写立即触发
2. **沉默触发**：超过 30 秒无新转写 且 新增 >= 3 条
3. **兜底上限**：距上次分析超过 600 秒（10 分钟）
4. **手动触发**：用户点击 ⚡ 按钮或在输入框发送消息

AI 输出 `"—"` 时静默丢弃（表示当前内容无新意）。每第 5 次分析时 System Prompt 会追加"全局地图"要求。自定义 System Prompt 存储在 `UserDefaults` key `customSystemPrompt`，非空时覆盖默认 Prompt。

## ASR 子进程 (asr-bridge)

Go 代码位于项目内 `asr-bridge/` 目录（从 speaklow 复制并适配），`ASRServerManager.swift` 通过 `#file` 宏自动定位。

启动流程：检查 `asr-bridge/bin/asr-bridge` 是否存在 → 不存在则调用 `go build -o bin/asr-bridge .` 编译 → 通过环境变量 `ASR_BRIDGE_PORT` 设置端口 → 启动进程 → 健康检查（最多等 15 秒，每 500ms 轮询 `GET /health`）。

Go 编译器查找顺序：`/opt/homebrew/bin/go` → `/usr/local/go/bin/go` → `/usr/local/bin/go`。

ASR WebSocket 连接中断时自动重连，最多 3 次。

## 编码规范

- **架构**：MVVM，`MeetingViewModel` 为唯一状态中心，`@MainActor` 保证 UI 更新在主线程
- **并发**：`async/await` + `Task { @MainActor [weak self] in ... }` 处理跨线程回调
- **日志**：每个文件顶部声明 `private let logger = Logger(subsystem: "MeetingAI", category: "模块名")`，关键路径打 log（入参、分支判断、异常、返回值）
- **错误处理**：异常通过 `appendChat(.system, ...)` 在 UI 中显示，同时 `logger.error(...)` 记录
- **内存安全**：异步回调中使用 `[weak self]` 避免循环引用

## 注意事项

- SPM executableTarget 构建的 SwiftUI macOS App 必须手动调用 `setActivationPolicy(.regular)` + `activate(ignoringOtherApps: true)`，否则窗口无法获得键盘焦点（见 `ContentView.swift` init）
- 麦克风权限在首次运行时弹窗授权，测试时注意
- MiniMax API 的 BaseURL 默认为 `api.minimaxi.com`（注意：不是 `api.minimax.chat`），可通过 config.json 的 `ai.baseURL` 覆盖
- MVP 无持久化聊天历史，关闭即丢弃；转写 txt 和 mp3 录音文件会保存到 sessions 目录
