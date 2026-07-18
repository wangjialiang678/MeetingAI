# 会议 AI 助手 (MeetingAI)

Mac 原生桌面应用，会议期间实时录音转写，AI 自动分析并产出洞察卡片，支持对话式交互；录音分片走后台说话人分离归档轨。

需求与行为的 source of truth 在 `openspec/`；现状综述见 `docs/stage-review-2026-05-23.md`，工程守则见 `docs/engineering-lessons-2026-05-23.md`，交接速览见 `docs/handoff-2026-07-18.md`。

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言/框架 | Swift 5.9 + SwiftUI，macOS 14+ |
| 构建工具 | Swift Package Manager (SPM)，executableTarget，依赖 alibabacloud-oss-swift-sdk-v2 |
| 录音采集 | AVAudioEngine，16kHz PCM16 单声道；录音文件 MP3（编码器不可用时自动 fallback 单声道 WAV） |
| 实时 ASR | asr-bridge（Go 子进程，端口默认 18089，**本机实际用 18090**，由 config.json 指定以避开 SpeakLow 的 18089，见 `docs/incident-asr-port-conflict-2026-07-18.md`），JSON WebSocket `ws://127.0.0.1:{port}/v1/stream`，DashScope qwen3-asr-flash-realtime |
| AI 分析 | 默认 **HTTP**（2026-07-18 起，Codex CLI 洞察实测 50s+ 延迟，降级为可选项）。本机走 `z-ai/glm-5.2` @ OpenRouter（config.json 指定，key 用 `OPENROUTER_API_KEY`）；代码默认 `qwen/qwen3.5-122b-a10b` @ NVIDIA。Codex CLI / Hybrid 仍可在设置里切换，Codex 失败自动回退 HTTP |
| 说话人分离 | 归档轨：会议中按 chunk 封存单声道 WAV → OSS 上传（官方 Swift SDK）→ Fun-ASR 非实时 HTTP → **逐分片 GLM 交叉纠错**（TranscriptRefiner，保守：仅高置信度识别错误）→ merge → 会议中滚动回填 UI（说话人段落替代对应时段实时转写，实时区只显示未覆盖尾巴） |
| 日志 | os.log（subsystem: "MeetingAI"）+ 每场会议 `.events.log` JSON Lines（复盘首选判据） |

## 目录结构

```
MeetingAI/
├── Package.swift               # SPM 配置，macOS 14，OSS SDK 依赖
├── asr-bridge/                 # Go ASR 代理（/health + /v1/stream，端口由 config.json 指定，本机 18090）
├── openspec/                   # 需求规格 source of truth（specs/ + changes/）
├── Sources/
│   ├── ContentView.swift       # @main 入口，顶部栏 + HSplitView 双面板
│   ├── MeetingViewModel.swift  # 核心状态机，@MainActor，触发/重连/事件日志都在这
│   ├── Models.swift            # TranscriptEntry / InsightCard（kind: insight|reply|summary|system）
│   ├── Config.swift            # AppConfig：api-vault.env + config.json + MEETINGAI_* 环境覆盖
│   ├── ASRServerManager.swift  # Go 子进程管理（编译/启动/健康检查/端口占用防御）
│   ├── ASRBridgePortGuard.swift# 端口被占决策：自家残留→清理，外来进程→报错不误杀
│   ├── ASRClient.swift         # JSON WebSocket 客户端（串行队列保护状态）
│   ├── AudioRecorder.swift     # 录音，双路输出 + AudioTapDrainGate（stop 时限时 drain）
│   ├── AIEngine.swift          # HTTP/Codex CLI 双后端，兼容 reasoning_content 解析
│   ├── MeetingContextBuilder.swift # 分析上下文分层（hot window/近期/长期）
│   ├── InsightDeduplicator.swift   # 洞察重复度检测（bigram Jaccard，阈值 0.85）
│   ├── InsightFeedView.swift   # 右侧洞察卡片流（模式切换、置顶、折叠）
│   ├── TranscriptView.swift    # 左侧实时转写 + 说话人分离回填区
│   ├── TranscriptMarkdownWriter.swift # .transcript.md 快照（保留回填区块）
│   ├── Diarization*.swift      # 归档轨：Chunker/Pipeline/OSS/FunASR/Merger/SessionGate/Backfill
│   └── SettingsView.swift      # 设置（自定义 Prompt、分析后端切换）
├── tests/                      # swiftc smoke + shell 脚本（见下）
├── scripts/                    # 真实 smoke / 彩排采集脚本
└── docs/                       # dev-log、stage-review、lessons、runtime-logs、research
```

## 常用命令

```bash
swift build                     # 构建（Debug）
swift run MeetingAI             # 运行（需麦克风权限 + api-vault.env 密钥）
bash tests/run-all.sh           # 一键回归：P0/P1 headless + P2 fixture GUI 主流程
bash tests/run-p0-p1.sh         # 仅 headless 基线（构建 + 全部 smoke + 代码正确性检查）
scripts/run-real-meeting-smoke.sh 90 75   # 真实麦克风+联网短 smoke，日志写 docs/runtime-logs/
scripts/run-real-meeting-rehearsal.sh     # 20-30 分钟真实彩排采集
```

清理遗留 bridge 进程时**不要用裸 `pkill asr-bridge`**（会误杀 SpeakLow 等其他项目的同名进程），用：
`pkill -f '会议中AI给建议.*asr-bridge'`。App 启动时已自带端口占用防御：自家残留自动清理，外来进程占用会明确报错。

## 配置与密钥

**API 密钥**（从 `~/.claude/api-vault.env` 自动读取；GUI App 不继承 shell env，故双读 process env + vault 文件）：
```
DASHSCOPE_API_KEY=...   # 实时 ASR（DashScope）
QWEN_API_KEY=...        # HTTP AI 后端（NVIDIA integrate endpoint）
OSS_ACCESS_KEY_ID=...   # 可选：Fun-ASR 说话人分离真实上传
OSS_ACCESS_KEY_SECRET=...
```

**应用配置**（`~/Library/Application Support/MeetingAI/config.json`，不存在则用默认值；本机当前配置）：
```json
{
  "asr": { "serverPort": 18090 },
  "ai": {
    "model": "z-ai/glm-5.2",
    "baseURL": "https://openrouter.ai/api/v1/chat/completions",
    "apiKeyEnv": "OPENROUTER_API_KEY"
  },
  "diarization": { "uploadBucket": "audio-asr-temp", "uploadStorage": "oss" }
}
```
注意：说话人分离上传**必须同时配** `uploadBucket` 和 `uploadStorage: "oss"`——只配 bucket 时管线会静默禁用（events.log 里 `diarization_pipeline_disabled` / `upload_storage_not_oss`，2026-07-18 真实彩排踩过）。
其他可用字段：`asr.language`（默认 zh）、`ai.autoAnalysisIntervalSeconds`（默认 300）、`ai.maxContextTokens`（默认 100000）。`ai.apiKeyEnv` 指定 HTTP 后端从哪个环境变量取 key（默认 `QWEN_API_KEY`），换模型供应商只需改 config，不用改代码。

常用环境覆盖：`MEETINGAI_ANALYSIS_BACKEND=http|codex_cli|hybrid`、`MEETINGAI_SESSIONS_DIR`、`MEETINGAI_UI_FIXTURE=1`、`MEETINGAI_SEGMENTED_DIARIZATION`、`MEETINGAI_DIARIZATION_CHUNK_SECONDS`、`MEETINGAI_DIARIZATION_UPLOAD_BUCKET`。

**会话产物**（`~/Library/Application Support/MeetingAI/sessions/`，同前缀多文件）：
`.txt`（仅 final 转写）、`.transcript.md`（含 partial 快照 + 说话人回填）、`.ai.md`（AI 卡片记录）、`.events.log`（JSON Lines 结构化事件，复盘首选）、`.chunks.jsonl`（分片生命周期）、`.diarized.jsonl`（说话人句子）、`.mp3` 或 `.wav`（录音）。

## AI 分析触发逻辑

均在 `MeetingViewModel`，**按文本长度触发，partial 计入**（不依赖 final 条数）：

| 模式 | 文本增量触发 | 沉默触发（10s 检查一次） | 最小输出间隔 |
|------|------------|------------|------------|
| 观察者 | 不主动分析 | 不触发 | ∞（手动点击会提示切换模式） |
| 顾问（默认） | ≥200 字 | 沉默 >60s 且新增 ≥50 字 | 180s |
| 研究员 | ≥100 字 | 沉默 >30s 且新增 ≥30 字 | 45s |

按需发言原则（2026-07-18 用户决策）：顾问模式 prompt 默认沉默（should_speak=false），仅关键盲点/方向性风险/行动项/真正新信息才发言；连续沉默兜底 5 次才强制发声。

- 兜底：距上次分析 >600s 且有新增内容
- 手动触发被限流/重复时有可见系统提示；自动触发静默跳过（写 `analysis_skipped` 事件）
- 新洞察与最近 3 张洞察卡 bigram Jaccard 相似度 ≥0.85 时丢弃（`analysis_discarded_duplicate` 事件），AI 输出 shouldSpeak=false 连续 3 次后强制发声
- 话题关键词重叠 <30% 时自动触发小结
- 系统消息使用独立的 `.system` 卡片类型，不再混入洞察

## 编码规范

- **架构**：MVVM，`MeetingViewModel` 为唯一状态中心，`@MainActor` 保证 UI 更新在主线程
- **并发**：`async/await` + `Task { @MainActor [weak self] in ... }`；跨线程可变状态用串行队列保护
- **日志**：每文件顶部 `Logger(subsystem: "MeetingAI", category: "模块名")`；关键状态转移和失败分支必打；**严禁输出 API key 值/预签名 URL query**；`.events.log` 中 home path 脱敏为 `~`
- **错误处理**：用户可见错误走 `.system` 卡片（简洁中文），原始细节进 logger
- **测试**：toolchain 无 XCTest，用 `swiftc + smoke 可执行` 模式；新逻辑先写 RED 再 GREEN；GUI 自动化收敛在 P2 单条 fixture 主路径，P0/P1 保持 headless
- **真实链路测试**：结论必须区分 PASS / FAIL / BLOCKED，环境阻塞不许伪装成通过

## 注意事项

- SPM executableTarget 的 SwiftUI App 必须手动 `setActivationPolicy(.regular)` + `activate(ignoringOtherApps: true)`（见 ContentView init）
- NVIDIA/Qwen 的 OpenAI-compatible 响应正文可能在 `message.reasoning_content` 而非 `content`，AIEngine 已兼容，勿回退
- 本机 MP3 编码可能不可用，录音自动 fallback 单声道 WAV；产物检查看"文件非空"而不是"路径存在"
- `.txt` 会议中按 final 追加（崩溃兜底），停止会议时由 `TranscriptStore` 用全部 entries（partial+final）重写为完整版；会议中的实时完整内容仍看 `.transcript.md`
- Fun-ASR `speaker_id` 不保证跨 chunk 指同一真人；不同 speaker 的相同短句不去重（宁可重复不误删）
- Fun-ASR 真实云端链路目前 BLOCKED：等 OSS bucket + 凭证配置（`MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1` smoke 会返回 BLOCKED）
