# Log 观察记录 — 2026-03-06

观察时间: 17:28 ~ 17:35 (约 7 分钟连续录音)
日志总行数: 4261 条
App 状态: 录音中，有人在说话（持续有 partial transcript）

---

## P0 — 阻断性问题

### 1. ASR 永远不出 final，AI 永远不触发

**现象**: 4261 条日志，零条 `isFinal=true`。全是 partial transcript。

**影响**: 所有 AI 分析触发逻辑（内容积累触发、静默触发、天花板触发）都依赖 `finalCount`——即 `transcriptEntries.filter(\.isFinal).count`。如果 ASR 不产生 final 事件，AI 分析永远不会被自动触发。

**根因分析**: DashScope qwen3-asr-flash-realtime 的实时模式下，`final` 可能只在以下时机出现:
- ASR 会话结束（发送 stop 消息）
- 检测到长静默（具体阈值不确定）
- 语句边界检测（VAD）

在连续开会场景下（说话人不断切换，没有长时间静默），final 可能很久不出现。

**建议方案**:
1. **客户端侧 VAD**: 不依赖 ASR 的 final，自己实现基于时间的断句逻辑。比如：同一个 partial 如果 2~3 秒没更新，视为一个"完整句子"，将当前 partial 标记为 isFinal=true
2. **基于 partial 内容变化触发**: 不再完全依赖 isFinal 计数，而是监测 partial 文本长度/变化量
3. **定时强制 final**: 每隔 N 秒，将当前积累的 partial 强制转为 final entry
4. **需要确认**: 查看 asr-bridge 的 stream.go 代码，确认 DashScope 的 final 事件触发机制

---

### [已修复] P0 修复方案

改为基于文本积累量（字符数）触发，不再依赖 `isFinal`：
- advisor 模式：每积累 200 字触发一次
- researcher 模式：每积累 100 字触发一次
- `buildAnalysisUserContent()` 也改为包含所有 entries（含 partial）
- `checkSilenceTrigger()` 同样改为基于文本量

### 1b. MiniMax API 返回 parseError

**现象**: 用户手动触发分析后，UI 显示 `[系统] AI 分析失败: Failed to parse response`

**原因**: `AIEngine.analyze()` 解析 MiniMax API 返回的 JSON 时，`choices[0].message.content` 路径解析失败。可能是：
- API 返回了错误结构（非标准 OpenAI 格式）
- API 返回了空 choices 数组
- 网络/认证问题导致返回了 HTML 错误页面

**建议**: 在 `AIEngine.analyze()` 中，parseError 之前打印 raw response body，方便定位具体原因。

---

## P1 — 重要但不阻断

### 2. os.log 的 `<private>` 遮蔽

**现象**: 所有 debug 级别的日志内容被 `<private>` 替代，无法看到实际的 transcript 文本或 Bridge event 类型。

**原因**: Apple os.log 默认对动态字符串插值使用 privacy redaction。需要显式标记 `\(text, privacy: .public)` 才能在 log stream 中看到内容。

**影响**: 调试困难。无法通过 log stream 确认 ASR 返回了什么内容、Bridge 收到了什么事件类型。

**建议**: 在开发阶段，对关键调试信息使用 `.public` privacy:
```swift
logger.debug("Transcript: isFinal=\(isFinal), text=\(text.prefix(50), privacy: .public)")
logger.debug("Bridge event: \(type, privacy: .public)")
```
发布前可以改回 `.private` 或用条件编译 `#if DEBUG`。

### 3. 日志噪音过大

**现象**: 7 分钟产生 4261 条日志，约 10 条/秒。绝大多数是:
- `Bridge event: <private>` (每个 partial 2 条)
- `partial: <private>` (每个 partial 1 条)
- `Transcript: isFinal=false` (每个 partial 1 条)

一个 partial 事件会产生 4 条日志行。

**影响**: 真正有价值的日志（Config、AI 分析、错误）被海量 partial 日志淹没。

**建议**:
- ASRClient 中的 `Bridge event` 和 `partial` 日志可以降为 trace 级别，或每 N 条打一次
- ViewModel 中 `isFinal=false` 的 transcript 日志可以降频（比如每 10 条打一次，或者只在文本长度有显著变化时打）
- 参考 AudioRecorder 的做法：第 1 条打、之后每 500 条打一次

### 4. Info 级别日志未出现在 stream 中

**现象**: `Config loaded`、`Starting meeting`、`Session file` 等 Info 级别日志没有出现。

**原因**: 这些日志在 app 启动/会议开始时就已经打了，而 log stream 是在 app 已经运行后才开始的。这不是 bug，但说明如果要完整观察，需要在 app 启动前就开始 log stream。

**建议**: 考虑在 app 内部也写一份日志文件（类似 session file），方便事后分析。

---

## P2 — 可改进

### 5. 系统消息混在 insightCards 里

**现象**: `appendSystemMessage()` 将系统消息（如"会议已开始"、"ASR 错误"）包装为 `[系统] xxx` 的 InsightCard(.insight 类型)。

**影响**:
- 系统消息和 AI 洞察混在一起，UI 上无法区分
- 系统消息也会被 saveAILog() 保存到 AI 记录文件里
- 系统消息也会被 `isOldAndUnpinned` 逻辑折叠

**建议**: 考虑给 InsightCard.Kind 新增一个 `.system` 类型，或者把系统消息放在独立的 array 里。

### 6. AI 分析无法手动触发（录音中）

**现象**: 因为 P0 问题（无 final），`triggerAnalysis()` 中 `guard finalCount > lastAnalysisEntryCount` 永远不满足，即使用户手动点击"立即分析"按钮也会提示"暂无新转写内容可分析"。

**影响**: 用户看到了 partial 文字在实时滚动，但点击分析按钮却说没有内容。体验矛盾。

**建议**: 手动触发时应该降低门槛，至少在有 partial 内容的情况下允许分析。

### 7. 最小间隔静默跳过无用户反馈

**现象**: `triggerAnalysis()` 因最小间隔未满足而静默 return（虽然加了 debug 日志），但用户无任何感知。

**影响**: 用户频繁点击"立即分析"按钮，什么都不发生，不知道为什么。

**建议**: 对手动触发和自动触发做区分——手动触发应该给用户一个提示（"距上次分析不足 2 分钟，请稍后"），自动触发可以静默跳过。

---

## 日志样本

### 唯一出现的日志类型（去重后）
```
[MeetingAI:ASRClient] Audio chunks sent: {1000,1500,...,4500}
[MeetingAI:ASRClient] Bridge event: <private>
[MeetingAI:ASRClient] partial: <private>
[MeetingAI:ViewModel] Transcript: isFinal=false, text=<private>
```

### 未出现的日志（期望但没看到）
```
[ViewModel] Config loaded: ...          ← app 启动时已打过
[ViewModel] Starting meeting...         ← 同上
[ViewModel] Triggering AI analysis ...  ← 因为无 final 所以未触发
[ViewModel] AI speaks: ...              ← 同上
[ViewModel] Auto trigger: ...           ← 同上
[AIEngine] Sending AI request: ...      ← 同上
```
