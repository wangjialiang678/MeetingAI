---
title: MeetingAI 架构文档
date: 2026-03-06
updated: 2026-07-18
status: active
audience: both
tags: [architecture]
---

# MeetingAI 架构文档

> **2026-07-18 对齐更新**：外部依赖、端口、模型与组件职责已按当前代码修订；更细的行为规格见 `openspec/specs/`，组件清单见根目录 `CLAUDE.md`。

## 系统概览

MeetingAI 是一个 Mac 原生 SwiftUI 应用，通过 SPM 构建为可执行目标（无 Xcode 项目）。应用采集麦克风音频，走两条轨道：实时轨流式发送到本地 asr-bridge 做低延迟转写并触发 AI 分析；归档轨把录音按 chunk 封存，后台上传 OSS 交给 Fun-ASR 做非实时说话人分离，结果回填 UI 与会后产物。

```
用户（麦克风）→ [MeetingAI.app] ─实时轨→ asr-bridge（Go 子进程，:18089）→ DashScope qwen3-asr-flash-realtime
                                ─分析→ Codex CLI（洞察）/ Qwen HTTP @ NVIDIA（总结、追问；回退目标）
                                ─归档轨→ chunk WAV → OSS 上传 → Fun-ASR 说话人分离 → 回填
                                ─落盘→ sessions/（.txt/.transcript.md/.ai.md/.events.log/.chunks.jsonl/录音）
```

## 上下文与边界

| 外部依赖 | 协议 | 说明 |
|---------|------|------|
| asr-bridge | WebSocket（ws://127.0.0.1:18089/v1/stream）+ GET /health | 项目内 Go 子进程，桥接 DashScope 云端 ASR |
| DashScope ASR | WebSocket（由 asr-bridge 代理） | qwen3-asr-flash-realtime，App 不直接连接 |
| Qwen HTTP AI | HTTPS（integrate.api.nvidia.com） | OpenAI 兼容 Chat Completions，兼容 `reasoning_content` 响应 |
| Codex CLI | 本机子进程 | Hybrid 模式下洞察优先后端，失败自动回退 HTTP |
| 阿里云 OSS | HTTPS（官方 Swift SDK） | 归档轨 chunk 上传 + GET 预签名 URL（凭证缺失时归档轨静默等待） |
| Fun-ASR | HTTPS（DashScope 非实时文件转写） | 说话人分离，submit → poll → 下载 transcription_url |
| 文件系统 | 本地 | 每场会议同前缀多产物保存到 Application Support/MeetingAI/sessions |

## 核心组件

### MeetingViewModel

- **职责**: 中央协调器，管理录音生命周期、ASR 回调、AI 触发逻辑、会话文件 I/O
- **关键状态**: `transcriptEntries`、`chatMessages`、`isRecording`、`isAnalyzing`
- **线程模型**: `@MainActor`，所有 UI 状态更新在主线程

### AudioRecorder

- **职责**: AVAudioEngine 麦克风采集，双路输出
- **输出路径 1**: PCM16 16kHz 音频帧 → ASR WebSocket
- **输出路径 2**: MP3 编码 → 本地文件录音

### ASRClient

- **职责**: JSON WebSocket 客户端，与本地 asr-bridge 通信；连接状态/音频计数用串行队列保护
- **输入**: PCM16 音频帧
- **输出**: `onTranscript(text, isFinal)` 回调 + 轻量生命周期事件回调（对齐 `.events.log`）
- **容错**: 连接错误时触发 `onError`；ViewModel 侧重连状态机（单一 pending task、指数退避 1→16s、达到上限提示放弃、generation guard 过滤旧连接回调）

### ASRServerManager

- **职责**: 管理项目内 Go `asr-bridge` 子进程的完整生命周期
- **流程**: 检查二进制是否存在 → 缺失时自动 `go build` → 端口占用防御（ASRBridgePortGuard：自家残留清理，外来进程报错）→ 启动子进程 → 健康检查（15s 内轮询 /health）→ 会议结束时终止
- **Go 源码路径**: 项目内 `asr-bridge/`（通过 `#file` 宏定位）

### AIEngine

- **职责**: 分析后端路由与调用封装（HTTP / Codex CLI / Hybrid）
- **HTTP 后端**: OpenAI 兼容 Chat Completions（Qwen @ NVIDIA integrate endpoint），兼容 `content` / 数组 content / `reasoning_content` 响应
- **Codex CLI 后端**: 本机子进程调用，Hybrid 下洞察优先走此后端，失败自动回退 HTTP
- **输出**: 结构化分析结果（shouldSpeak / kind / topicKeywords / content + 执行元数据）

### Config

- **职责**: 配置加载，两个来源合并
- **API 密钥**: 从 `~/.claude/api-vault.env` 读取环境变量
- **应用配置**: 从 `~/Library/Application Support/MeetingAI/config.json` 读取 JSON

## 数据模型

```swift
struct TranscriptEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let text: String
    let isFinal: Bool      // false = partial（临时），true = final（确认）
}

struct InsightCard: Identifiable {
    let id: UUID
    let timestamp: Date
    var content: String
    var kind: Kind          // .insight | .reply | .summary | .system
    var isPinned: Bool
    var userQuery: String?
    var execution: AnalysisExecutionMetadata?   // 后端选路/回退/耗时
}
```

## 数据流

```
Microphone (AVAudioEngine)
    ↓ PCM16 16kHz（tap 回调经 AudioTapDrainGate，stop 时限时 drain）
AudioRecorder ──→ MP3/WAV 录音文件
    ├─→ onAudioData ──→ ASRClient (WebSocket) ──→ asr-bridge (:18089) ──→ DashScope ASR   [实时轨]
    │        ↓ onTranscript(text, isFinal)
    │   MeetingViewModel
    │        ├─→ transcriptEntries[] ──→ TranscriptView（左侧面板）
    │        ├─→ .txt（final）/.transcript.md（含 partial 快照）/.events.log
    │        └─→ 文本长度/沉默/兜底触发 ──→ AIEngine（Codex CLI / Qwen HTTP）
    │             ↓ 结构化结果（重复度检测后落卡）
    │        insightCards[] ──→ InsightFeedView（右侧卡片流）
    └─→ DiarizationAudioChunker ──→ chunk WAV + .chunks.jsonl                             [归档轨]
             ↓ chunk 封存后
        DiarizationPipeline: OSS 上传 → Fun-ASR submit/poll → merge → .diarized.jsonl + 回填
```

## AI 智能触发机制

按文本长度触发（partial 计入），分三种模式（任一满足即触发分析）：

| 触发器 | 观察者 | 顾问（默认） | 研究员 | 检查频率 |
|--------|-------|------------|--------|---------|
| 文本增量 | 不触发 | ≥200 字 | ≥100 字 | 每次收到转写 |
| 静默检测 | 不触发 | >60s 且新增 ≥50 字 | >30s 且新增 ≥30 字 | 每 10 秒 |
| 上限兜底 | 不触发 | 距上次分析 >600s | 同左 | 每 10 秒 |
| 最小输出间隔 | ∞ | 120s | 45s | — |
| 手动触发 | 提示切换模式 | 受最小间隔限流（有可见提示） | 同左 | 用户操作 |

新洞察与最近 3 张洞察卡相似度 ≥0.85（字符 bigram Jaccard）时丢弃并写 `analysis_discarded_duplicate` 事件。

## AI Prompt 策略

- 转写文本按时间分层标记：`[最新]`（<10min）、`[近期]`（10-30min）、`[早期]`（>30min）
- 每次分析包含上次 AI 回复内容，避免重复
- 每 5 次分析触发一次"全局地图"综合总结
- 支持用户自定义 System Prompt（通过 `@AppStorage`）

## 关键决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 构建方式 | SPM executable（无 Xcode 项目） | 最简单的 SwiftUI App 构建方式 |
| ASR 方案 | 复用 audio-asr-go 子进程 | 避免重复造轮子，Go 服务已稳定 |
| LLM 选型 | MiniMax M2.5 | 长上下文支持好（100K tokens），中文能力强 |
| 触发策略 | 三触发器独立判断 | 比固定间隔更智能，避免无意义分析 |
| 窗口焦点 | 手动 `setActivationPolicy(.regular)` | SPM executable SwiftUI App 的已知限制 |

## 已知限制

- 不支持说话人识别（实时 ASR 不支持 diarization）
- 仅采集麦克风音频，不支持系统音频
- asr-server 依赖本地 Go 编译器，首次构建需要网络
- AI 分析为无状态调用（每次发送完整上下文），长会议可能接近 token 上限
