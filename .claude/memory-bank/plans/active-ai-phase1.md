STATUS: PENDING

# Phase 1: 主动 AI 助手重构

## 目标

将 MeetingAI 从"定期总结器"改为"主动洞察助手"。改完后 AI 会自己判断值不值得说话，输出以卡片形式展示，用户可以 📌 标记重要内容。

## 步骤清单

### Step 1: 数据模型 — Models.swift
- [ ] `ChatMessage` → `InsightCard`
- [ ] 新增 `Kind` enum: `.insight` / `.reply` / `.summary`
- [ ] 新增 `isPinned: Bool`、`userQuery: String?`
- [ ] 新增 `AIMode` enum: `.observer` / `.advisor` / `.researcher`
- [ ] 保留 `TranscriptEntry` 不变

### Step 2: AI 输出结构化 — AIEngine.swift
- [ ] 新增 `analyzeStructured()` 方法，返回解析后的结构体（should_speak, content, kind, topic_keywords）
- [ ] 保留现有 `analyze()` 方法给用户提问用
- [ ] JSON 解析失败时 fallback 为纯文本

### Step 3: Prompt 改造 — MeetingViewModel.swift
- [ ] 重写 `buildDefaultSystemPrompt()` → 要求 AI 返回 JSON，包含 should_speak 判断
- [ ] 新增 `buildSummaryPrompt()` 用于节点总结
- [ ] 新增 `buildUserReplyPrompt()` 用于用户提问的回复
- [ ] `buildAnalysisUserContent()` 保持基本不变（分层标签逻辑复用）

### Step 4: 触发逻辑重写 — MeetingViewModel.swift
- [ ] 新增 `@Published var aiMode: AIMode`（存 @AppStorage）
- [ ] `handleTranscript()` 中的触发逻辑按模式区分阈值：
  - observer: 不触发主动分析
  - advisor: 每 5 条 final 或 60s 静默
  - researcher: 每 3 条 final 或 30s 静默
- [ ] 新增最小输出间隔控制（advisor: 2min, researcher: 45s）
- [ ] `triggerAnalysis()` 改用 `analyzeStructured()`，根据 should_speak 决定是否显示
- [ ] 简单话题切换检测：比较前后 topic_keywords，变化大时触发节点总结
- [ ] `chatMessages` 全部改为 `insightCards`
- [ ] `appendChat()` 改为 `appendCard()`

### Step 5: 用户提问 — MeetingViewModel.swift
- [ ] `sendUserMessage()` 改为创建 `.reply` 类型的 InsightCard
- [ ] 回复卡片带 `userQuery` 字段

### Step 6: 卡片 UI — ChatView.swift → InsightFeedView.swift
- [ ] 文件重命名
- [ ] `ChatBubble` → `InsightCardView`
- [ ] 三种 kind 分别渲染：
  - `.insight`: 普通卡片
  - `.reply`: 顶部显示灰色 "你问: xxx"
  - `.summary`: 有分割线 + "阶段小结" 标题
- [ ] 每张卡片右下角 📌 按钮
- [ ] 旧卡片自动折叠（>15min 且未 📌）

### Step 7: 顶栏模式切换 — ContentView.swift
- [ ] 顶栏加 `Picker` 三档切换（观察者/顾问/研究员）
- [ ] 绑定 viewModel.aiMode
- [ ] "立即分析"按钮保留

### Step 8: 会话保存 — MeetingViewModel.swift
- [ ] `stopMeeting()` 时新增 `saveAILog()` 方法
- [ ] 保存为 `{session}-ai.md`
- [ ] 📌 卡片提取到文件开头

### Step 9: 编译验证
- [ ] `swift build` 通过
- [ ] 手动冒烟测试：开始会议 → 说话 → 看 AI 是否出卡片 → 📌 → 结束 → 检查保存文件

## 影响文件

| 文件 | 改动类型 |
|------|---------|
| `Models.swift` | 重写 |
| `AIEngine.swift` | 新增方法 |
| `MeetingViewModel.swift` | 大量改动 |
| `ChatView.swift` → `InsightFeedView.swift` | 重命名 + 重写 |
| `ContentView.swift` | 小改（顶栏加 Picker） |
| `SettingsView.swift` | 小改（默认 prompt 展示更新） |
| `AudioRecorder.swift` | 不变 |
| `ASRClient.swift` | 不变 |
| `ASRServerManager.swift` | 不变 |
| `Config.swift` | 不变 |
| `TranscriptView.swift` | 不变 |

## 风险

| 风险 | 缓解 |
|------|------|
| AI 不按 JSON 格式返回 | fallback：解析失败当纯文本处理，kind 默认 insight |
| should_speak 判断太保守（一直不说话） | 顾问模式下如果连续 3 次 should_speak=false 且有新内容，强制输出一次 |
| MiniMax 不支持 JSON mode | 不依赖 response_format 参数，纯靠 prompt 约束 + 解析容错 |
