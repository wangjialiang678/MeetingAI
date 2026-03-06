# 设计文档：ASR 引擎迁移至 qwen3-asr-flash-realtime

## 背景

当前 MeetingAI 使用 `audio-asr-go` 作为 ASR 子进程，通过 DashScope 旧版协议（paraformer 模型）实现语音转写。现需切换到 `qwen3-asr-flash-realtime` 模型，复用 speaklow 项目的 `asr-bridge` Go 代码（复制到本项目，无外部依赖）。

## 目标

1. 将 speaklow 的 asr-bridge Go 代码复制到本项目 `asr-bridge/` 目录
2. 修改 Swift 侧 `ASRServerManager` 指向本地 asr-bridge
3. 重写 `ASRClient.swift` 适配新的 JSON WebSocket 协议
4. 修改 `Config.swift` 默认端口改为 18089
5. `AudioRecorder.swift`、`MeetingViewModel.swift`、`AIEngine.swift` 等不改动

## 架构变化

```
改前：
  麦克风 → AudioRecorder (PCM16) → ASRClient (binary WS) → audio-asr-go:18080 → DashScope paraformer
                                                             ↑ 外部依赖

改后：
  麦克风 → AudioRecorder (PCM16) → ASRClient (JSON WS)  → asr-bridge:18089  → DashScope qwen3-asr
                                                             ↑ 本项目内置
```

## 文件变更清单

### 新增：`asr-bridge/` 目录（Go 代码，从 speaklow 复制并适配）

从 `speaklow-macvoiceinput/asr-bridge/` 复制以下文件到 `MeetingAI/asr-bridge/`：

| 文件 | 用途 | 需要修改 |
|------|------|---------|
| `main.go` | HTTP 服务入口、路由、中间件 | 是：日志路径改 MeetingAI、移除 refine 路由和 transcribe-sync 路由（MeetingAI 不需要）、健康检查端点改为 `/healthz` 与现有 Swift 代码一致 |
| `stream.go` | 核心流式 WebSocket ASR 代理 | 否：原样复制 |
| `hotword.go` | 热词加载（corpus.text） | 否：原样复制（无热词文件时自动跳过） |
| `env.go` | .env 文件加载 | 是：env 搜索路径改为 `~/.claude/api-vault.env`（与 MeetingAI 一致） |
| `go.mod` | Go 模块定义 | 是：模块名改为 `meetingai/asr-bridge` |
| `go.sum` | 依赖锁定 | 原样复制 |

**不复制的文件**：
- `transcribe_sync.go` — MeetingAI 只用流式，不需要批量转写
- `refine.go` — MeetingAI 不需要 LLM 润色功能

### 修改：`Sources/ASRServerManager.swift`

**当前代码关键点**：
- `goProjectDir` 硬编码为 `/Users/michael/projects/组件模块/audio-asr-suite/go/audio-asr-go`
- 编译命令：`go build -o outputPath ./cmd/asr-server`
- 启动参数：`--listen :\(port)`
- 健康检查：`GET /healthz`

**修改内容**：

```swift
// 改前
private let goProjectDir = "/Users/michael/projects/组件模块/audio-asr-suite/go/audio-asr-go"

// 改后：使用项目内置的 asr-bridge 目录
// 通过 Bundle.main.bundlePath 或 #file 定位到项目根目录下的 asr-bridge/
private var goProjectDir: String {
    // SPM executable: 源码在 Sources/ 同级的 asr-bridge/
    // 用 #file 定位 Sources/ASRServerManager.swift → 上一级 → asr-bridge/
    let sourceFile = URL(fileURLWithPath: #file)
    return sourceFile.deletingLastPathComponent()  // Sources/
        .deletingLastPathComponent()                // 项目根目录
        .appendingPathComponent("asr-bridge")
        .path
}
```

编译命令修改：
```swift
// 改前
buildProcess.arguments = ["build", "-o", outputPath, "./cmd/asr-server"]

// 改后
buildProcess.arguments = ["build", "-o", outputPath, "."]
```

二进制名修改：
```swift
// 改前
let binaryPath = "\(goProjectDir)/bin/asr-server"

// 改后
let binaryPath = "\(goProjectDir)/bin/asr-bridge"
```

启动参数：asr-bridge 不需要 `--listen` 参数，端口通过环境变量 `ASR_BRIDGE_PORT` 传入：
```swift
// 改前
proc.arguments = ["--listen", ":\(port)"]

// 改后
// asr-bridge 通过环境变量 ASR_BRIDGE_PORT 设置端口，无命令行参数
proc.arguments = []
env["ASR_BRIDGE_PORT"] = String(port)
```

健康检查端点修改：
```swift
// 改前
guard let url = URL(string: "http://127.0.0.1:\(port)/healthz") else { return false }

// 改后：asr-bridge 的健康检查端点是 /health
guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
```

### 修改：`Sources/ASRClient.swift`（重写）

**当前协议**（audio-asr-go DashScope 原生格式）：
- 连接 `ws://127.0.0.1:{port}/api-ws/v1/inference`
- 上行：`run-task` JSON 启动 → 原始 binary PCM 数据 → `finish-task` JSON 结束
- 下行：`result-generated` 事件（payload.output.sentence.text / sentence_end）

**新协议**（asr-bridge 简化 JSON 格式）：
- 连接 `ws://127.0.0.1:{port}/v1/stream`
- 上行：全部 JSON over WebSocket text frame
- 下行：全部 JSON over WebSocket text frame

完整重写如下：

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "MeetingAI", category: "ASRClient")

class ASRClient {
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var isConnected = false

    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// 连接 asr-bridge 的 /v1/stream WebSocket 端点
    func connect(port: Int) {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/v1/stream") else { return }
        logger.info("Connecting WebSocket to \(url)")
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        sendStart()
    }

    /// 发送 start 消息，告知 bridge 开始 ASR 会话
    private func sendStart() {
        let startMsg: [String: Any] = [
            "type": "start",
            "model": "qwen3-asr-flash-realtime",
            "sample_rate": 16000,
            "format": "pcm"
        ]
        sendJSON(startMsg) { [weak self] error in
            if let error {
                self?.onError?("start 消息发送失败: \(error.localizedDescription)")
            } else {
                self?.receiveLoop()
            }
        }
    }

    /// 发送 PCM16 音频数据（Base64 编码）
    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        let audioMsg: [String: Any] = [
            "type": "audio",
            "data": data.base64EncodedString()
        ]
        sendJSON(audioMsg)
    }

    /// 发送 stop 消息，告知 bridge 录音结束
    private func sendStop() {
        let stopMsg: [String: Any] = ["type": "stop"]
        sendJSON(stopMsg)
    }

    func disconnect() {
        sendStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isConnected = false
            self?.webSocket?.cancel(with: .goingAway, reason: nil)
            self?.webSocket = nil
        }
    }

    // MARK: - Private

    private func sendJSON(_ dict: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            completion?(NSError(domain: "ASRClient", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "JSON 编码失败"]))
            return
        }
        webSocket?.send(.string(text)) { error in completion?(error) }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self?.handleMessage(text)
                }
                self?.receiveLoop()
            case .failure(let error):
                self?.onError?("WebSocket 接收错误: \(error.localizedDescription)")
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        logger.debug("Bridge event: \(type)")
        switch type {
        case "started":
            isConnected = true
            logger.info("ASR session started")

        case "partial":
            if let partialText = json["text"] as? String, !partialText.isEmpty {
                onTranscript?(partialText, false)
            }

        case "final":
            if let finalText = json["text"] as? String, !finalText.isEmpty {
                onTranscript?(finalText, true)
            }

        case "finished":
            logger.info("ASR session finished")
            isConnected = false

        case "error":
            let errorMsg = json["error"] as? String ?? "unknown bridge error"
            onError?("ASR Bridge 错误: \(errorMsg)")

        default:
            break
        }
    }
}
```

**关键变化对比**：

| 维度 | 改前（audio-asr-go） | 改后（asr-bridge） |
|------|---------------------|-------------------|
| WS 端点 | `/api-ws/v1/inference` | `/v1/stream` |
| 启动握手 | `run-task` JSON（含 task_id） | `start` JSON（含 model/sample_rate） |
| 音频发送 | `webSocket.send(.data(rawPCM))` | `webSocket.send(.string(JSON{type:audio, data:base64}))` |
| 结束 | `finish-task` JSON | `stop` JSON |
| 中间结果 | `result-generated` + sentence.text + sentence_end=false | `partial` + text |
| 最终结果 | `result-generated` + sentence.text + sentence_end=true | `final` + text |
| 会话结束 | 无明确事件 | `finished` |
| 错误 | `task-failed` | `error` + error 字段 |

### 修改：`Sources/Config.swift`

```swift
// 改前
asrServerPort: jsonConfig["asr"]?["serverPort"] as? Int ?? 18080,

// 改后
asrServerPort: jsonConfig["asr"]?["serverPort"] as? Int ?? 18089,
```

### 不改动的文件

| 文件 | 理由 |
|------|------|
| `AudioRecorder.swift` | PCM16 16kHz 单声道输出格式完全兼容，`onAudioData` 回调接口不变 |
| `MeetingViewModel.swift` | `onTranscript(text, isFinal)` 回调签名不变，所有触发逻辑、状态管理无需改动 |
| `AIEngine.swift` | 与 ASR 无关 |
| `ContentView.swift` | UI 层不涉及 |
| `TranscriptView.swift` | 展示层不涉及 |
| `ChatView.swift` | 展示层不涉及 |
| `SettingsView.swift` | 设置层不涉及 |
| `Models.swift` | 数据模型不变 |
| `Package.swift` | SPM 配置不变（Go 代码不参与 SPM 构建） |

## asr-bridge Go 代码适配清单

### `main.go` 修改

1. **日志路径**：`SpeakLow-bridge.log` → `MeetingAI-bridge.log`
2. **移除不需要的路由**：删除 `transcribe-sync` 和 `refine` 相关代码
   - 删除 `mux.HandleFunc("/v1/transcribe-sync", ...)` 行
   - 删除 `mux.HandleFunc("/v1/refine", ...)` 行
   - 删除 `initConfigPaths()` 和 `loadRefinePrompt()` 调用
3. **健康检查端点不变**：保持 `/health`（Swift 侧 ASRServerManager 改为 `/health`）
4. 其余保持不变

### `env.go` 修改

env 搜索路径改为与 MeetingAI 一致：
```go
// 改前
candidates := []string{
    expandHome("~/.config/speaklow/.env"),
    sameDir(".env"),
}

// 改后
candidates := []string{
    expandHome("~/.claude/api-vault.env"),
    sameDir(".env"),
}
```

### `stream.go` — 不修改

原样复制。所有协议逻辑、静音检测（pcmRMS）、corpus leak 过滤（isCorpusLeak/isFillerOnly）均保持。

### `hotword.go` — 不修改

原样复制。MeetingAI 目前不使用热词，无热词文件时自动跳过（`initHotwords` 打印 skip 日志即返回）。

### `go.mod` 修改

```go
// 改前
module speaklow/asr-bridge

// 改后
module meetingai/asr-bridge
```

### 不复制的文件

- `transcribe_sync.go` — 批量转写，MeetingAI 不需要
- `refine.go` — LLM 润色，MeetingAI 不需要

## MeetingViewModel 集成验证

`MeetingViewModel.startMeeting()` 中的调用链不变：

```swift
// 1. ASRServerManager.start() — 编译并启动 asr-bridge（改了路径和编译命令）
// 2. ASRClient() — 创建客户端（重写了协议）
// 3. client.onTranscript = ... — 回调签名 (String, Bool) 不变
// 4. client.onError = ... — 回调签名 (String) 不变
// 5. client.connect(port:) — 方法签名不变
// 6. AudioRecorder.onAudioData → asrClient.sendAudio(data) — 签名不变
```

`MeetingViewModel.stopMeeting()` 中：
```swift
// asrClient?.disconnect() — 方法签名不变（内部改为发 stop JSON）
// serverManager?.stop() — 方法签名不变
```

`reconnectASR()` 中：
```swift
// ASRClient() + connect(port:) — 接口不变，可直接复用
```

**结论**：`MeetingViewModel.swift` 零改动。

## 数据流对比

```
改前：
  AudioRecorder.onAudioData(Data)          // raw PCM16 bytes
    → ASRClient.sendAudio(Data)            // webSocket.send(.data(rawPCM))
    → audio-asr-go                         // 直接转发 binary 到 DashScope
    → DashScope paraformer

改后：
  AudioRecorder.onAudioData(Data)          // raw PCM16 bytes（不变）
    → ASRClient.sendAudio(Data)            // data.base64EncodedString() → JSON → webSocket.send(.string)
    → asr-bridge                           // 解码 base64 → pcmRMS 静音过滤 → 转发到 DashScope
    → DashScope qwen3-asr-flash-realtime
```

唯一的数据格式变化在 `ASRClient.sendAudio`：从发送原始 binary 改为 base64 编码后包在 JSON 中发送。这在 Swift 侧由重写的 `ASRClient` 处理，`AudioRecorder` 无感知。

## 目录结构（改后）

```
MeetingAI/
├── Package.swift
├── PRD.md
├── asr-bridge/                    # [新增] 从 speaklow 复制并适配
│   ├── go.mod
│   ├── go.sum
│   ├── main.go                    # 适配：日志路径、移除无关路由
│   ├── stream.go                  # 原样复制
│   ├── hotword.go                 # 原样复制
│   └── env.go                     # 适配：env 路径
├── Sources/
│   ├── ContentView.swift
│   ├── MeetingViewModel.swift     # 不改
│   ├── Models.swift               # 不改
│   ├── Config.swift               # 改：默认端口 18089
│   ├── ASRServerManager.swift     # 改：指向 asr-bridge、编译命令、健康检查端点
│   ├── ASRClient.swift            # 重写：新协议
│   ├── AudioRecorder.swift        # 不改
│   ├── AIEngine.swift             # 不改
│   ├── TranscriptView.swift       # 不改
│   ├── ChatView.swift             # 不改
│   └── SettingsView.swift         # 不改
└── docs/
    └── design-asr-migration.md    # 本文档
```

## 测试计划

### 冒烟测试

1. `cd asr-bridge && go build -o bin/asr-bridge .` — 确认编译通过
2. `swift build` — 确认 Swift 编译通过
3. `swift run MeetingAI` → 点击"开始会议" → 对着麦克风说话 → 验证左侧转写面板有输出
4. 等待 30 秒沉默 → 验证 AI 自动分析触发
5. 点击"结束会议" → 验证 sessions 目录有 txt 和 mp3 文件

### 回归项

- [ ] 转写文本正常显示（partial 实时更新、final 固定）
- [ ] AI 自动分析正常触发（内容积累 8 条 / 沉默 30 秒 / 兜底 600 秒）
- [ ] 手动触发分析（点击闪电按钮）
- [ ] 用户对话（输入框发送消息）
- [ ] ASR 断线重连（最多 3 次）
- [ ] 会话文件保存（txt + mp3）
- [ ] 导入历史转写文件

## 风险

| 风险 | 概率 | 缓解 |
|------|------|------|
| Go 首次编译需要下载依赖（gorilla/websocket） | 必然 | `go build` 会自动 `go mod download`，只需网络 |
| qwen3-asr 静音时幻听 | 低 | asr-bridge 已内置 pcmRMS 静音过滤 + isFillerOnly 填充词过滤 |
| Base64 编码增加数据量（约 33%） | 必然 | 本地 localhost 传输，带宽不是瓶颈 |
| 端口 18089 被占用 | 极低 | config.json 可配置 |
