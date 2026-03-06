---
title: MeetingAI - 会议 AI 助手
date: 2026-03-06
status: active
audience: human
---

# MeetingAI - 会议 AI 助手

> Mac 原生桌面应用，会议期间实时录音转写，AI 自动分析讨论内容并给出建议。

## 功能

- 实时麦克风录音 + ASR 语音转写（左侧面板滚动显示）
- AI 智能触发分析：内容积累 / 静默检测 / 定时上限，三种独立触发机制
- 手动一键分析（立即分析按钮）
- 对话式 AI 交互（右侧面板，可随时向 AI 提问）
- 会议录音保存（MP3 格式）
- 会话转写文本自动保存
- 自定义 AI System Prompt

## 快速开始

### 前置要求

- macOS 14+
- Swift 5.9+（Xcode 15+ 或对应 Swift toolchain）
- Go 编译器（用于构建 ASR 服务，首次运行自动编译）
- API 密钥：
  - `DASHSCOPE_API_KEY` — 阿里云 DashScope ASR 服务
  - `MINIMAX_API_KEY` — MiniMax M2.5 大模型

### 配置 API 密钥

将密钥写入 `~/.claude/api-vault.env`：

```bash
DASHSCOPE_API_KEY=your_dashscope_key
MINIMAX_API_KEY=your_minimax_key
```

### 构建与运行

```bash
swift build
swift run MeetingAI
```

首次运行时，App 会自动编译 asr-server（Go 子进程），需要等待几秒。

## 项目结构

```
Sources/
  ContentView.swift          # App 入口，窗口布局
  MeetingViewModel.swift     # 核心协调器：录音、ASR、AI 触发、文件 I/O
  AudioRecorder.swift        # 麦克风采集（PCM16 + MP3 双路）
  ASRClient.swift            # WebSocket ASR 客户端
  ASRServerManager.swift     # Go asr-server 子进程管理
  AIEngine.swift             # MiniMax M2.5 HTTP API
  Config.swift               # 配置加载（API Key + JSON 配置）
  Models.swift               # 数据模型
  TranscriptView.swift       # 转写面板 UI
  ChatView.swift             # AI 对话面板 UI
  SettingsView.swift         # 设置界面
Package.swift                # SPM 包定义
```

## 配置

App 使用 JSON 配置文件 `~/Library/Application Support/MeetingAI/config.json`：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `asr.serverPort` | 18080 | ASR 服务端口 |
| `asr.language` | zh | ASR 识别语言 |
| `ai.autoAnalysisIntervalSeconds` | 300 | AI 自动分析间隔（秒） |
| `ai.model` | MiniMax-M2.5 | LLM 模型 |
| `ai.maxContextTokens` | 100000 | 最大上下文 token 数 |

## 文档

详细文档见 [docs/](docs/) 目录：

- [产品需求](docs/specs/prd.md)
- [系统架构](docs/specs/architecture.md)
