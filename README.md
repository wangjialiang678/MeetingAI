---
title: MeetingAI - 会议 AI 助手
date: 2026-03-06
status: active
audience: human
---

# MeetingAI - 会议 AI 助手

> Mac 原生桌面应用，会议期间实时录音转写，AI 自动分析讨论内容并给出建议。

## OpenSpec Source Of Truth

项目现已正式接入 OpenSpec，后续需求澄清和行为变更以 `openspec/` 为准：

- 当前主规格：`openspec/specs/`
- 当前进行中的需求澄清：`openspec/changes/clarify-active-meeting-copilot/`

如果旧的 `docs/` 文档与 OpenSpec 不一致，优先以 OpenSpec 为准。

## 功能

- 实时麦克风录音 + ASR 语音转写（qwen3-asr 实时流）
- **会议中滚动替代**：录音按分片自动上传 Fun-ASR 做说话人分离，结果经 GLM 与实时转写交叉纠错后，实时替换转写面板对应时段内容（说话人段落为主体，实时转写只显示最新尾巴）
- AI 按需洞察：按文本增量/沉默/兜底触发，模型默认沉默、仅有真正值得说的才发声（观察者/顾问/研究员三模式）；洞察重复度自动去重
- 手动一键分析 + 对话式 AI 交互（洞察卡片流，支持置顶/折叠）
- AI 后端可配：默认 HTTP（本机 GLM 5.2 @ OpenRouter），Codex CLI / Hybrid 可选
- 会话产物自动保存：`.txt`（含 partial 的完整转写）、`.transcript.md`、`.ai.md`、`.events.log`（结构化事件）、`.diarized.jsonl`（说话人句子）、录音（MP3/WAV）
- 工程防御：ASR 端口占用预检（不误杀同名进程）、健康检查身份校验、DashScope 直连绕代理、静音期不断连、重连去重+指数退避
- 自定义 AI System Prompt

## 快速开始

### 前置要求

- macOS 14+
- Swift 5.9+（Xcode 15+ 或对应 Swift toolchain）
- Go 编译器（用于构建 ASR 服务，首次运行自动编译）
- API 密钥：
  - `DASHSCOPE_API_KEY` — 阿里云 DashScope ASR 服务
  - `QWEN_API_KEY` — 当前默认 HTTP AI 后端
  - `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` — 可选，启用真实 Fun-ASR 说话人分离上传时使用

### 配置 API 密钥

将密钥写入 `~/.claude/api-vault.env`：

```bash
DASHSCOPE_API_KEY=your_dashscope_key
QWEN_API_KEY=your_qwen_key
# 可选：启用 OSS/Fun-ASR 说话人分离真实上传
OSS_ACCESS_KEY_ID=your_oss_access_key_id
OSS_ACCESS_KEY_SECRET=your_oss_access_key_secret
# OSS_SESSION_TOKEN=your_sts_token
```

### 构建与运行

```bash
swift build
swift run MeetingAI
```

首次运行时，App 会自动编译 `asr-bridge`（Go 子进程），需要等待几秒。

### 一键测试

```bash
bash tests/run-all.sh
```

该入口会依次执行 P0/P1 自动基线和 P2 fixture GUI 主流程。

### 真实彩排日志采集

真实麦克风 + 联网模型测试前，建议用脚本启动并采集日志：

```bash
scripts/run-real-meeting-smoke.sh 90
scripts/run-real-meeting-rehearsal.sh
```

`run-real-meeting-smoke.sh` 是短链路自动 smoke，会启动 App、点击开始/结束、尝试用系统语音制造麦克风输入，并检查 `.events.log` / `.transcript.md`。默认会用 `MEETINGAI_ANALYSIS_BACKEND=http` 验证在线 HTTP 模型链路，可通过同名环境变量覆盖；失败码 `2` 表示本机输入设备或权限阻塞，不等同于代码失败。

启用真实 OSS/Fun-ASR 说话人分离 smoke：

```bash
MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1 \
MEETINGAI_DIARIZATION_UPLOAD_BUCKET=your-private-bucket \
scripts/run-real-meeting-smoke.sh 90 75
```

该模式会要求 OSS 上传、Fun-ASR 轮询、`.diarized.jsonl`、Markdown 说话人回填和签名 URL 不落日志；缺 bucket 或 OSS 凭证时返回 BLOCKED。

`run-real-meeting-rehearsal.sh` 用于 20-30 分钟人工彩排采集。两个脚本都会写入 `docs/runtime-logs/{RUN_ID}/`，包含 App stdout、Unified Log、bridge log 和最新 session 文件清单。

## 项目结构

```
Sources/
  ContentView.swift          # App 入口，窗口布局
  MeetingViewModel.swift     # 核心协调器：录音、ASR、AI 触发、文件 I/O
  AudioRecorder.swift        # 麦克风采集（PCM16 + MP3 双路）
  DiarizationModels.swift    # 说话人分离分片与合并模型
  DiarizationChunker.swift   # 录音分片 WAV 写入与 chunk 生命周期日志
  DiarizationBackfillWriter.swift # 说话人标签 JSONL 与 transcript.md 回填
  DiarizationProviderBoundary.swift # 上传/provider-neutral 请求响应边界
  DiarizationOSSSupport.swift # OSS 配置归一化与 object key 生成
  DiarizationOSSUploader.swift # OSS 上传与 GET 预签名 URL
  DiarizationFunASRProvider.swift # DashScope Fun-ASR submit/poll/result parser
  DiarizationPipeline.swift  # chunk 上传、provider 任务、合并与回填流水线
  ASRClient.swift            # WebSocket ASR 客户端
  ASRServerManager.swift     # Go asr-bridge 子进程管理
  AIEngine.swift             # Qwen HTTP API + Codex CLI Hybrid 后端
  Config.swift               # 配置加载（API Key + JSON 配置）
  Models.swift               # 数据模型
  TranscriptView.swift       # 转写面板 UI
  InsightFeedView.swift      # AI 洞察面板 UI
  SettingsView.swift         # 设置界面
Package.swift                # SPM 包定义
```

## 配置

App 使用 JSON 配置文件 `~/Library/Application Support/MeetingAI/config.json`：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `asr.serverPort` | 18089 | ASR 服务端口。**本机必须配置为 18090**（18089 属于 SpeakLow，见 `docs/incident-asr-port-conflict-2026-07-18.md`） |
| `asr.language` | zh | ASR 识别语言 |
| `ai.autoAnalysisIntervalSeconds` | 300 | AI 自动分析间隔（秒） |
| `ai.model` | qwen/qwen3.5-122b-a10b | LLM 模型 |
| `ai.maxContextTokens` | 100000 | 最大上下文 token 数 |
| `diarization.enabled` | true | 是否启用本地说话人分离音频分片；可用 `MEETINGAI_SEGMENTED_DIARIZATION=0/1` 覆盖 |
| `diarization.chunkDurationSeconds` | 60 | 本地分片时长；可用 `MEETINGAI_DIARIZATION_CHUNK_SECONDS` 覆盖 |
| `diarization.provider` | dashscopeFunASR | 说话人分离 provider 占位，不包含密钥 |
| `diarization.uploadStorage` | unconfigured | 上传存储占位：`unconfigured` / `oss` / `presignedURL` |
| `diarization.uploadRegion` | cn-beijing | OSS region；可用 `MEETINGAI_DIARIZATION_UPLOAD_REGION` 覆盖 |
| `diarization.uploadEndpoint` | https://oss-cn-beijing.aliyuncs.com | OSS endpoint；可用 `MEETINGAI_DIARIZATION_UPLOAD_ENDPOINT` 覆盖 |
| `diarization.uploadBucket` | 空 | 上传 bucket 占位，不包含密钥 |
| `diarization.objectPrefix` | meetingai/chunks | OSS object 前缀 |
| `diarization.presignTTLSeconds` | 21600 | GET 预签名 URL 有效期 |
| `diarization.funASRBaseURL` | https://dashscope.aliyuncs.com/api/v1 | Fun-ASR API base URL |
| `diarization.pollIntervalSeconds` | 5 | Fun-ASR task 轮询间隔 |
| `diarization.pollTimeoutSeconds` | 600 | 单个 chunk 轮询超时 |
| `diarization.speakerCount` | 空 | 可选，2-100 时传给 Fun-ASR，否则自动判断 |

## 会话产物

每场会议会写入 `~/Library/Application Support/MeetingAI/sessions/`，文件名前缀为开始时间：

- `.txt`：final 转写的纯文本时间线
- `.transcript.md`：当前完整转写快照，包含“最终/临时”状态
- `.mp3` / `.wav`：会议录音（MP3 不可用时自动写 WAV）
- `.ai.md`：AI 洞察、追问回复和后端执行状态
- `.events.log`：JSON Lines 结构化事件日志，只记录凭证是否加载，不记录 API key 值
- `.chunks.jsonl`：说话人分离音频 chunk 生命周期，记录本地 chunk created/waiting
- `{timestamp}-chunks/*.wav`：单声道 PCM WAV 分片，默认保留
- `.diarized.jsonl`：说话人分离句子结果，配置 OSS 后由 Fun-ASR 后台回填

## 说话人分离

当前实时 ASR 链路用于低延迟 partial/final 展示，不支持说话人分离。说话人分离采用独立归档轨：会议中定时封存音频 chunk，配置 OSS 后上传并调用 DashScope Fun-ASR 非实时文件识别开启 `diarization_enabled`，再把带 `speaker_id` 的结果回填到会话转写和 UI。

默认 `diarization.uploadStorage=unconfigured` 时只产出本地 chunk 和 waiting 事件；设为 `oss` 且配置 bucket/凭证后会启用真实上传和轮询。调研记录见 [docs/research/2026-05-23-diarization-segmented-transcription.md](docs/research/2026-05-23-diarization-segmented-transcription.md)。

## 文档

详细文档见 [docs/](docs/) 目录：

- [产品需求](docs/specs/prd.md)
- [系统架构](docs/specs/architecture.md)
- [阶段性回顾](docs/stage-review-2026-05-23.md)
- [工程经验沉淀](docs/engineering-lessons-2026-05-23.md)
