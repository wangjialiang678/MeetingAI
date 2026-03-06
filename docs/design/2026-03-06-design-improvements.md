---
title: "设计建议: MeetingAI 改进方向"
date: 2026-03-06
status: active
audience: both
tags: [design, improvements]
---

# 设计建议: MeetingAI 改进方向

基于对全部 11 个源文件的代码审查，按优先级整理的改进建议。

---

## P0: 长会议必崩 — AI 上下文管理

### 问题

当前每次 AI 分析都发送**完整转写文本**（`buildAnalysisUserContent()`）。一场 1 小时会议大约产生 1-2 万字转写，接近 MiniMax M2.5 的 100K token 上限。2 小时以上的会议必然超限，AI 调用直接失败。

### 现状代码

```
// MeetingViewModel.swift:391-403
let tiers = transcriptEntries.filter(\.isFinal).map { ... }
// 所有 final 条目全部拼接发送
```

### 建议方案

**滚动摘要 + 分层上下文**：

1. 维护一个 `cumulativeSummary: String`，每次 AI 分析后更新
2. 发送给 AI 的内容变为：`上次摘要(~2K) + 近期转写(~5K) + 最新转写(全量)`
3. 当总 token 数接近阈值（如 80K），对"近期"部分也做压缩

```
[累积摘要] 前 40 分钟讨论了定价策略和竞品分析...（AI 生成的摘要）
[近期] 最近 10 分钟的转写
[最新] 最近 3 分钟的转写（全量保留）
```

这样即使 8 小时会议，发送量也维持在可控范围。

---

## P0: AI 流式响应

### 问题

当前 `AIEngine.analyze()` 等待完整响应返回后才显示。MiniMax M2.5 生成长文本时可能需要 10-20 秒，用户只看到"分析中..."转圈，体验差。

### 建议方案

MiniMax API 支持 `"stream": true`，返回 SSE 格式的 token 流。改造为：

1. `AIEngine` 新增 `analyzeStream()` 方法，通过 `AsyncSequence` 逐 token 返回
2. `MeetingViewModel` 收到 token 后实时追加到 `chatMessages` 的最后一条
3. ChatView 自然响应数据变化，实现打字机效果

收益：首字延迟从 10s+ 降到 ~1s，用户立刻看到 AI 在思考。

---

## P1: 多轮对话上下文

### 问题

用户通过 `sendUserMessage()` 提问时，AI 只看到当前转写 + 用户的单条追问。**不包含之前的对话历史**。用户说"继续刚才那个话题"、"你说的第二点展开一下"，AI 无法理解。

### 现状代码

```swift
// MeetingViewModel.swift:191
let userContent = buildAnalysisUserContent() + "\n\n用户追问：\(text)"
// 只拼接了 userContent，没有 chatMessages 历史
```

### 建议方案

将 `chatMessages` 中最近 N 条 user/assistant 消息构建为标准 messages 数组传给 API：

```swift
let messages = [
    ["role": "system", "content": systemPrompt],
    // 最近 5 轮对话历史
    ...recentChatHistory.map { ["role": $0.role.rawValue, "content": $0.content] },
    ["role": "user", "content": userContent]
]
```

需要控制总量，避免历史消息 + 转写超出 token 限制。

---

## P1: Markdown 渲染

### 问题

AI 回复经常包含 Markdown 格式（标题、列表、加粗、代码块），但 `ChatBubble` 用纯 `Text()` 渲染，格式标记原样显示，可读性差。

### 建议方案

两种路径：

1. **轻量方案**：用 [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)（SPM 包），直接 `Markdown(message.content)` 替换 `Text(message.content)`
2. **零依赖方案**：用 `AttributedString(markdown:)` （macOS 13+ 原生支持），但表格/代码块支持有限

推荐方案 1，一行代码解决。

---

## P1: 启动时配置校验

### 问题

API Key 缺失或为空时，App 能正常启动但功能全部失败。用户要等到点击"开始会议"后才看到错误，且错误信息不明显（混在聊天消息里）。

### 建议方案

App 启动后立即检查：

1. `DASHSCOPE_API_KEY` 和 `MINIMAX_API_KEY` 是否非空
2. Go 编译器是否存在
3. asr-server 源码目录是否可达

缺失时在主界面顶部显示**醒目的警告横幅**（红色背景），列出缺失项和修复步骤。不要只在聊天区显示系统消息。

---

## P1: AI 对话也要保存

### 问题

当前会话结束时只保存转写文本（`.txt`）和录音（`.mp3`），AI 的分析结果和用户对话**丢失**。但 AI 的分析往往比原始转写更有价值。

### 建议方案

`stopMeeting()` 时额外保存一个 `{session}-chat.md`：

```markdown
# 会议 AI 分析记录 - 2026-03-06 14:30

## [14:30:05] 系统
会议已开始...

## [14:35:22] AI
### 当前讨论主题
...

## [14:36:01] 用户
总结一下刚才的讨论

## [14:36:15] AI
...
```

保存为 Markdown 格式，方便后续阅读和搜索。

---

## P2: DateFormatter 性能

### 问题

`TranscriptView.formatTime()` 和 `ChatBubble.formatTime()` 每次调用都 `new DateFormatter()`。在快速滚动场景（大量转写条目），这是不必要的性能开销。

### 建议方案

```swift
// 共享一个静态 formatter
private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()
```

微小改动，但在 1000+ 条目的长会议中有明显差异。

---

## P2: ASR 服务日志捕获

### 问题

```swift
// ASRServerManager.swift:42-43
proc.standardOutput = FileHandle.nullDevice
proc.standardError = FileHandle.nullDevice
```

asr-server 的所有日志被丢弃。当 ASR 出问题时（如 DashScope 限流、网络超时），没有任何诊断信息。

### 建议方案

将 stderr 重定向到文件（如 `~/Library/Logs/MeetingAI/asr-server.log`），或至少在 debug 模式下输出到 `os.log`。不需要显示给用户，但要能查到。

---

## P2: 转写文本搜索

### 问题

长会议中转写面板可能有数百条记录，用户无法快速定位某个讨论点。

### 建议方案

在转写面板顶部添加搜索框：

- 实时过滤/高亮匹配文本
- Cmd+F 快捷键触发
- 搜索结果间 上/下箭头 跳转

实现简单：`transcriptEntries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }`

---

## P2: 键盘快捷键

### 问题

当前只有 Cmd+Return 发送消息。作为会议场景工具，应尽量减少鼠标操作。

### 建议

| 快捷键 | 功能 |
|--------|------|
| `Cmd+Return` | 发送消息（已有） |
| `Cmd+Shift+A` | 立即分析 |
| `Cmd+R` | 开始/结束会议 |
| `Cmd+F` | 搜索转写 |
| `Cmd+E` | 导出当前会话 |

---

## P3: 可选的 LLM 后端

### 问题

硬绑定 MiniMax M2.5。如果用户想用其他模型（DeepSeek、Qwen、本地 Ollama），需要改代码。

### 建议方案

因为 `AIEngine` 已经使用 OpenAI 兼容格式，只需让 `baseURL` 和 `model` 可在设置界面配置即可。大多数国产 LLM 和 Ollama 都兼容 OpenAI 格式。

在 `SettingsView` 增加 LLM 配置区：

- Base URL
- Model Name
- API Key（可选覆盖）

---

## P3: 会议暂停/恢复

### 问题

当前只有"开始会议"和"结束会议"。会议中间休息时无法暂停录音（不停录会产生大量无用的静默/杂音转写，干扰 AI 分析质量）。

### 建议方案

"暂停录音"按钮：停止音频采集和 ASR 发送，但不断开 WebSocket 连接和不结束会话。恢复时继续。

---

## 总结

| 优先级 | 改进项 | 复杂度 | 收益 |
|:---:|--------|:---:|------|
| P0 | AI 上下文管理（滚动摘要） | 中 | 解决长会议必崩问题 |
| P0 | AI 流式响应 | 中 | 首字延迟 10s→1s |
| P1 | 多轮对话上下文 | 低 | 对话连贯性 |
| P1 | Markdown 渲染 | 低 | AI 回复可读性 |
| P1 | 启动配置校验 | 低 | 新手友好 |
| P1 | AI 对话保存 | 低 | 保留分析价值 |
| P2 | DateFormatter 缓存 | 极低 | 长会议滚动性能 |
| P2 | ASR 日志捕获 | 低 | 排障能力 |
| P2 | 转写搜索 | 低 | 长会议导航 |
| P2 | 键盘快捷键 | 低 | 操作效率 |
| P3 | 可选 LLM 后端 | 低 | 灵活性 |
| P3 | 会议暂停/恢复 | 低 | 避免噪音干扰 |
