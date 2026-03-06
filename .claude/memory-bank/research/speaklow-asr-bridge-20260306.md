# 调研报告: Speaklow 项目后端 ASR 实现

**日期**: 2026-03-06
**任务**: 调研 speaklow-macvoiceinput 项目后端（asr-bridge）的 ASR 实现，特别是 qwen3-asr 和 DashScope 实时 WebSocket 的完整实现细节，供 MeetingAI 项目参考复用。

---

## 调研摘要

speaklow 的 `asr-bridge` 是一个 Go 编写的独立 HTTP 服务（默认端口 18089），作为 Swift 客户端与 DashScope 之间的代理。它实现了三条 API 路由：流式 WebSocket ASR（`/v1/stream`）、同步批量转写（`/v1/transcribe-sync`）、LLM 文本润色（`/v1/refine`）。其 ASR 实现使用 **qwen3-asr-flash-realtime**（OpenAI Realtime 兼容协议），比 MeetingAI 当前使用的 audio-asr-go 更新（qwen3 vs 旧版 paraformer）。核心代码结构清晰，可直接参考或移植。

---

## 现有代码分析

### 相关文件

**后端（Go，asr-bridge）**
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/main.go` - HTTP 服务入口，路由注册，中间件（CORS/日志），日志轮转
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/stream.go` - 核心：流式 WebSocket ASR，包含完整的 DashScope 协议实现、静音检测（RMS）、corpus leak 过滤
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/transcribe_sync.go` - 批量同步转写，qwen3-asr-flash HTTP API（multimodal generation 端点）
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/refine.go` - LLM 文本润色，qwen-flash OpenAI-compatible，支持可配置 prompt 和风格，文件热重载
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/hotword.go` - 热词管理，构建 corpus.text 格式
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/env.go` - 多路径 .env 加载（godotenv）

**前端（Swift）**
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/ASRBridgeManager.swift` - Go 子进程管理（启动/健康检查/自动重启，最多 3 次）
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/StreamingTranscriptionService.swift` - Swift 侧 WebSocket 客户端，对接 bridge /v1/stream
- `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AudioRecorder.swift` - AVFoundation 录音，PCM16 16kHz，支持多设备枚举

### 现有模式

**协议层（Client ↔ Bridge）**
- 客户端先发 `{type:"start", model:..., sample_rate:16000, format:"pcm"}`
- 随后循环发送 `{type:"audio", data:"<base64 PCM16>"}` 音频块
- 录音结束发送 `{type:"stop"}`
- Bridge 回传：`started | partial | final | finished | error`
  - `partial`：实时中间结果（stash + confirmed text 拼接）
  - `final`：句子完结（sentence_end: true）
  - `finished`：整个 session 完结

**协议层（Bridge ↔ DashScope）**
- 连接 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime`
- Header：`Authorization: Bearer {DASHSCOPE_API_KEY}`、`OpenAI-Beta: realtime=v1`
- 握手流程：收到 `session.created` → 发 `session.update`（含 modalities、format、sample_rate、language、corpus）→ 收到 `session.updated` → 开始推流
- 音频推送：`input_audio_buffer.append`（base64 PCM16）
- 结束：`input_audio_buffer.commit` + `session.finish`
- DashScope 事件：
  - `conversation.item.input_audio_transcription.text`：stash=中间结果，text=确认结果
  - `conversation.item.input_audio_transcription.completed`：最终 transcript
  - `session.finished`：session 完结

**静音检测**
- pcmRMS 函数计算 PCM16 LE 的 RMS 值
- RMS < 150 视为环境噪音，speech 检测到（RMS >= 150）后才开始转发音频给 DashScope
- 防止 ASR hallucination（静音期假转写）

**Corpus Leak 过滤**
- qwen3-asr-flash-realtime 已知 Bug：在静音时会把 session.update 中的 corpus.text 当作转写结果输出
- 过滤条件：`isCorpusLeak`（检测特征字符串）、`isFillerOnly`（嗯/啊/呃等填充词）

**同步批量 API**
- 端点：`POST https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
- 模型：`qwen3-asr-flash`（非 realtime，适合上传完整录音文件）
- 格式：multimodal messages，audio 字段用 `data:audio/wav;base64,...` 格式
- language_hints: ["zh", "en"]

### 可复用组件

1. `stream.go`：完整的 DashScope qwen3-asr WebSocket 代理实现（可直接移植到 audio-asr-go 或独立使用）
2. `pcmRMS` 函数：静音检测，防幻听的核心逻辑
3. `isCorpusLeak` / `isFillerOnly`：qwen3-asr-flash-realtime 专用过滤逻辑
4. `hotword.go`：热词 corpus.text 构建（带音近提示格式）
5. `refine.go`：转写后 LLM 润色（文件热重载、风格系统、长度兜底保护）
6. `ASRBridgeManager.swift`：Go 子进程管理（含自动重启限速、健康监控）
7. `StreamingTranscriptionService.swift`：Swift WebSocket 客户端（protocol delegate 设计，clean 的 start/sendAudio/stop/disconnect 接口）

---

## 技术方案

### 方案 A: 直接复用 speaklow asr-bridge 二进制

**描述**: 将 speaklow 的 asr-bridge 作为 MeetingAI 的 ASR 子进程替换掉现有的 audio-asr-go

**优点**:
- 使用最新 qwen3-asr-flash-realtime 模型（比 paraformer 更准确）
- 已包含静音过滤、corpus leak 修复等生产级处理
- 端口 18089，不与 audio-asr-go（18080）冲突
- 三条路由（流式/批量/润色）功能完整

**缺点**:
- MeetingAI 当前的 ASRClient.swift 对接的是 audio-asr-go 的 WebSocket 协议，需要改写
- asr-bridge 的客户端协议（start/audio/stop JSON over WS）与 audio-asr-go 不同

**实现复杂度**: 中（主要是 Swift 侧 ASRClient 适配）

### 方案 B: 将 stream.go 的 DashScope 协议移植到 audio-asr-go

**描述**: 把 speaklow 中 qwen3-asr 的握手/推流/事件处理逻辑合并到现有 audio-asr-go

**优点**:
- 对 MeetingAI 的 Swift 代码改动最小（沿用现有 ASRClient.swift 接口）
- audio-asr-go 已有完整的测试基础设施

**缺点**:
- 需要修改 Go 项目代码，工作量较大
- 两个项目维护分散

**实现复杂度**: 中高

### 方案 C: 参考协议实现，在 MeetingAI Swift 侧直接对接 DashScope WebSocket

**描述**: 参考 speaklow 的协议文档，在 Swift 直接实现 DashScope 握手协议（绕过 Go 中间层）

**优点**:
- 架构最简，无 Go 子进程依赖
- 调试路径短

**缺点**:
- Swift 无法设置 WebSocket 自定义 Header（Authorization），必须通过本地代理绕过
- 实际上 MeetingAI 已经有 Go 子进程（audio-asr-go），收益不明显

**实现复杂度**: 高（受限于 Swift 浏览器 WebSocket 限制）

---

## 推荐方案

**推荐**: 方案 A（直接复用 speaklow asr-bridge）

**理由**:
1. asr-bridge 是生产级实现，已处理所有已知问题（静音检测、corpus leak、自动重连、热词）
2. 模型更新（qwen3-asr-flash-realtime）比现有 paraformer 识别质量更好
3. Swift 侧仅需适配协议（参考 StreamingTranscriptionService.swift 即可），改动范围可控
4. asr-bridge 的 /v1/transcribe-sync 还提供批量转写能力，可以作为流式 ASR 的降级备用

---

## 实施建议

### 关键步骤
1. 在 MeetingAI 的 `ASRServerManager.swift` 中新增 asr-bridge 路径（`/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/asr-bridge`）
2. 改写 `ASRClient.swift`，实现 speaklow 协议（start/audio/stop JSON，接收 started/partial/final/finished/error）
3. 在 `AudioRecorder.swift` 保持 PCM16 16kHz 单声道输出，chunk 大小与现有保持一致即可
4. 测试流程：启动 bridge → 连接 WS → 发 start → 推送音频 → 发 stop → 接收 finished

### 风险点
- **端口冲突**: audio-asr-go 用 18080，asr-bridge 用 18089，无冲突，但如果两者同时运行会造成混乱 - 缓解措施: 切换后停用 audio-asr-go，或通过环境变量 `ASR_BRIDGE_PORT` 统一管理
- **corpus leak Bug**: qwen3-asr-flash-realtime 在静音时会输出热词 corpus 内容 - 缓解措施: MeetingAI 不使用热词功能，此风险不存在；如将来启用，需在 ASRClient 侧加 isCorpusLeak 过滤
- **静音期假转写**: 无语音时 ASR 会产生"嗯"/"啊"等幻听 - 缓解措施: asr-bridge 已在 Go 侧用 pcmRMS < 150 和 isFillerOnly 过滤

### 依赖项
- `DASHSCOPE_API_KEY` 环境变量（asr-bridge 启动时必须）
- asr-bridge 编译产物路径（需要预先 `cd asr-bridge && go build -o asr-bridge .`）
- gorilla/websocket v1.5.3、godotenv v1.5.1

---

## 关键技术细节

### DashScope qwen3-asr WebSocket 协议摘要

```
连接：wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime
Header：Authorization: Bearer {KEY}
        OpenAI-Beta: realtime=v1

握手：
  ← session.created
  → session.update { modalities:["text"], input_audio_format:"pcm", sample_rate:16000,
                     input_audio_transcription:{language:"zh"}, turn_detection:null }
  ← session.updated

推流：
  → input_audio_buffer.append { audio: "<base64 PCM16 LE 16kHz>" }
  ← conversation.item.input_audio_transcription.text { stash:"...", text:"..." }  (streaming)
  ← conversation.item.input_audio_transcription.completed { transcript:"..." }   (sentence end)

结束：
  → input_audio_buffer.commit
  → session.finish
  ← session.finished
```

### 批量同步转写 API

```
POST https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation
Authorization: Bearer {KEY}
Content-Type: application/json

{
  "model": "qwen3-asr-flash",
  "input": {
    "messages": [
      {"role": "user", "content": [{"audio": "data:audio/wav;base64,..."}]}
    ]
  },
  "parameters": { "asr_options": { "language_hints": ["zh","en"] } }
}

Response: output.choices[0].message.content[0].text
```

---

## 参考资料

- speaklow asr-bridge 源码: `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/`
- speaklow Swift 客户端: `/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/`
- DashScope Realtime ASR 文档: https://help.aliyun.com/zh/model-studio/developer-reference/realtime-speech-recognition
