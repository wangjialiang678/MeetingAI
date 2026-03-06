---
title: MeetingAI 架构文档
date: 2026-03-06
status: active
audience: both
tags: [architecture]
---

# MeetingAI 架构文档

## 系统概览

MeetingAI 是一个 Mac 原生 SwiftUI 应用，通过 SPM 构建为可执行目标（无 Xcode 项目）。应用采集麦克风音频，流式发送到本地 ASR 服务进行实时转写，并定期调用 LLM 分析会议内容。

```
用户（麦克风）→ [MeetingAI.app] → asr-server（Go 子进程，localhost:18080）
                                → MiniMax API（云端 LLM）
                                → 本地文件系统（会话保存）
```

## 上下文与边界

| 外部依赖 | 协议 | 说明 |
|---------|------|------|
| asr-server | WebSocket（ws://localhost:18080） | Go 子进程，桥接 DashScope 云端 ASR |
| DashScope ASR | WebSocket（由 asr-server 代理） | 阿里云语音识别，App 不直接连接 |
| MiniMax API | HTTPS（api.minimax.chat） | OpenAI 兼容格式的 Chat Completions |
| 文件系统 | 本地 | 会话转写 .txt + 录音 .mp3 保存到 Application Support |

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

- **职责**: WebSocket 客户端，遵循 DashScope 协议与本地 asr-server 通信
- **输入**: PCM16 音频帧
- **输出**: `onTranscript(text, isFinal)` 回调
- **容错**: 连接错误时触发 `onError`，ViewModel 处理重连（最多 3 次）

### ASRServerManager

- **职责**: 管理 Go `asr-server` 子进程的完整生命周期
- **流程**: 检查二进制是否存在 → 缺失时自动 `go build` → 启动子进程 → 健康检查 → 会议结束时终止
- **Go 源码路径**: `~/projects/组件模块/audio-asr-suite/go/audio-asr-go/cmd/asr-server`

### AIEngine

- **职责**: MiniMax M2.5 HTTP API 封装
- **接口格式**: OpenAI 兼容 Chat Completions（system + user 消息）
- **调用方式**: `analyze(systemPrompt:, userContent:) async throws -> String?`

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

struct ChatMessage: Identifiable {
    let id: UUID
    let timestamp: Date
    let role: MessageRole   // .system | .user | .assistant
    let content: String
}
```

## 数据流

```
Microphone (AVAudioEngine)
    ↓ PCM16 16kHz
AudioRecorder ──→ MP3 文件（本地保存）
    ↓ onAudioData
ASRClient (WebSocket) ──→ asr-server (:18080) ──→ DashScope ASR
    ↓ onTranscript(text, isFinal)
MeetingViewModel
    ├─→ transcriptEntries[] ──→ TranscriptView（左侧面板）
    ├─→ appendToSessionFile() ──→ .txt 文件
    └─→ Smart Trigger 判断
         ↓ triggerAnalysis()
    AIEngine (MiniMax HTTP)
         ↓
    chatMessages[] ──→ ChatView（右侧面板）
```

## AI 智能触发机制

三种独立触发条件（任一满足即触发分析）：

| 触发器 | 条件 | 检查频率 |
|--------|------|---------|
| 内容积累 | 新增 8 条 final ASR 条目 | 每次收到 final 转写时 |
| 静默检测 | 30 秒无新转写 + 至少 3 条新条目 | 每 10 秒检查 |
| 上限计时器 | 距上次分析超过 600 秒 | 每 10 秒检查 |
| 手动触发 | 用户点击"立即分析"按钮 | 用户操作 |

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
