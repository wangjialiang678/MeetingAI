---
title: "设计: 技术与架构方案"
date: 2026-03-06
status: active
audience: ai
tags: [design, architecture, technical]
---

# 设计: 技术与架构方案

支撑交互方案落地的技术改动。按改动范围从小到大排列。

---

## 1. 数据模型改动

### ChatMessage → InsightCard

```swift
struct InsightCard: Identifiable {
    let id: UUID
    let timestamp: Date
    let content: String           // AI 输出的文本（Markdown）
    let kind: Kind                // 卡片类型
    var isPinned: Bool = false    // 📌 标记
    let userQuery: String?        // 如果是应答，记录用户的原始提问

    enum Kind {
        case insight    // AI 主动输出
        case reply      // 用户提问后的回复
        case summary    // 节点总结
    }
}
```

Kind 仅影响渲染样式（summary 有分割线标题，reply 显示原始提问），不影响逻辑。

### AI 模式

```swift
enum AIMode: String, CaseIterable {
    case observer   // 观察者：只回答，不主动
    case advisor    // 顾问（默认）：有想法就说，但克制
    case researcher // 研究员：积极输出
}
```

存到 `@AppStorage("aiMode")`，顶栏切换。

---

## 2. AI 触发逻辑改造

### 现状

三个独立定时/定量触发器 → 调用同一个 `triggerAnalysis()`。机械、不区分场景。

### 改为：连续分析 + AI 自判断

核心思路：**每次有足够新内容时都让 AI 看一眼，但 AI 自己决定说不说。**

```
新转写到达（累积 N 条 final）
    ↓
组装 prompt，调用 LLM
    ↓
AI 返回结构化 JSON:
{
    "should_speak": true/false,
    "content": "...",
    "kind": "insight" | "summary"
}
    ↓
should_speak == true → 创建 InsightCard 显示
should_speak == false → 丢弃，等下一轮
```

**节奏控制**（硬性规则，不依赖 AI 判断）：

| 模式 | 最小输出间隔 | 分析触发频率 |
|------|------------|------------|
| 观察者 | 不主动输出 | 不触发主动分析 |
| 顾问 | 2 分钟 | 每 5 条 final 或 60 秒静默 |
| 研究员 | 45 秒 | 每 3 条 final 或 30 秒静默 |

节点总结单独触发：检测到话题切换信号或 30 分钟无总结。

### 话题切换检测（简单方案）

不需要复杂的 NLP。让 AI 在每次分析时同时输出当前讨论的核心关键词（2-3 个），和上一次比较。如果关键词变化超过一半，判定为话题切换，触发节点总结。

```json
{
    "should_speak": true,
    "content": "...",
    "kind": "insight",
    "topic_keywords": ["定价", "竞品", "市场"]
}
```

---

## 3. Prompt 工程

### System Prompt 改造

当前的 system prompt 已经有"没什么值得说就输出 —"的规则，方向是对的。需要加强：

```
你是一位旁听会议的思维伙伴。你的输出会直接显示给正在开会的人。

规则：
1. 你必须返回 JSON 格式（schema 见下方）
2. should_speak: 你真的有新东西要说吗？重复已有观点、说显而易见的话 = false
3. 好的输出：没人提过的角度、对讨论方向的质疑、具体可操作的建议、
   对含混讨论的清晰化提炼
4. 坏的输出：总结大家说过的话、"可以考虑..."式的模糊建议、离题发散
5. 一两句话说清楚。会议中没人有空读长文。
6. 你可以有立场。可以质疑。可以提反对意见。不要当和事佬。

JSON schema:
{
    "should_speak": boolean,
    "content": string,      // Markdown，2-5 句话
    "kind": "insight" | "summary",
    "topic_keywords": string[]   // 2-3 个当前讨论核心词
}
```

用户提问时走单独的 prompt（不需要 should_speak 判断，问了就答）。

### 节点总结的 Prompt

```
会议讨论发生了话题转换（或会议即将结束）。请输出阶段小结。

格式：
- "确定了"：已达成共识的事项
- "没结论的"：讨论了但没有结论的事项
- "待跟进"：需要后续行动的事项

没有的类别就不写。不要凑数。
```

### 用户提问的 Prompt

```
用户在会议中向你提问。基于会议转写内容回答。
要求：精炼、直接、结合会议上下文。不要长篇大论，会议还在继续。
```

---

## 4. 流式响应

### 改动范围

`AIEngine.analyze()` 改为支持 SSE 流式返回。

由于 AI 现在返回 JSON，流式处理需要注意：
- 流式接收 token，拼接完整 JSON
- JSON 解析成功后再渲染卡片
- 或者：先流式显示 content 字段内容，JSON 完成后再解析 kind 等元数据

建议方案：**请求时加 `"stream": true`，逐 token 拼接，显示时先用 insight 类型渲染文本部分，JSON 完成后更新 kind。** 这样用户立刻看到文字，不需要等完整 JSON。

### 流式 + should_speak 的冲突

如果 AI 决定 `should_speak: false`，流式输出会先显示内容再被丢弃，体验差。

解决：流式模式下不解析 should_speak。改为在 prompt 中要求"不值得说就返回空 JSON `{}`"。收到空 JSON 就不显示。由于空 JSON 只有 2 个字符，延迟可忽略。

---

## 5. 多轮对话上下文

用户提问时，需要包含之前的对话历史。但主动洞察不需要（每次是独立分析）。

```swift
func buildUserQueryMessages(query: String) -> [[String: String]] {
    var messages: [[String: String]] = [
        ["role": "system", "content": userQuerySystemPrompt]
    ]

    // 最近 3 轮对话历史（仅 reply 类型的卡片）
    let recentReplies = insightCards
        .filter { $0.kind == .reply }
        .suffix(6)  // 3 轮 = 6 条（问+答）

    for card in recentReplies {
        if let q = card.userQuery {
            messages.append(["role": "user", "content": q])
        }
        messages.append(["role": "assistant", "content": card.content])
    }

    // 当前转写 + 用户新问题
    messages.append(["role": "user", "content": buildContext() + "\n\n" + query])
    return messages
}
```

---

## 6. 上下文管理（长会议）

每次发给 AI 的转写文本采用滚动窗口：

```
[摘要] 前 30 分钟讨论摘要（AI 生成，~500 字）
[近期] 最近 10 分钟完整转写
[最新] 最近 3 分钟完整转写
```

每次节点总结后，把总结内容追加到摘要，丢弃对应的原始转写。这样即使 4 小时会议，上下文也不会超限。

实现：在 MeetingViewModel 中维护一个 `contextSummary: String`，每次 kind == summary 时更新。

---

## 7. 会话保存

### 新增 AI 信息流保存

`stopMeeting()` 时，在现有 .txt 和 .mp3 之外，新增一个 `{session}-ai.md`：

```swift
func saveAILog() {
    let pinned = insightCards.filter(\.isPinned)
    let all = insightCards

    var md = "# 会议记录 - \(dateString)\n\n"

    if !pinned.isEmpty {
        md += "## 📌 标记的要点\n\n"
        for card in pinned {
            md += "> \(card.content)\n\n"
        }
    }

    md += "## 完整信息流\n\n"
    for card in all {
        md += "### \(timeString(card.timestamp))\n\n"
        if let q = card.userQuery {
            md += "*你问: \(q)*\n\n"
        }
        md += "\(card.content)\n\n"
    }

    // 写入文件
}
```

---

## 8. UI 组件改动

| 组件 | 改动 |
|------|------|
| `ChatView.swift` | 重命名为 `InsightFeedView.swift`，气泡改卡片，加 📌 按钮，加旧卡片折叠 |
| `ChatBubble` | 重命名为 `InsightCard`（View），三种 kind 分别渲染 |
| `ContentView.swift` | 顶栏加 AI 模式切换 Picker |
| `MeetingViewModel.swift` | `chatMessages` 改为 `insightCards`，触发逻辑重写 |
| `AIEngine.swift` | 加 `analyzeStream()` 方法，解析 JSON 输出 |
| `Models.swift` | `ChatMessage` 改为 `InsightCard` 模型 |
| `SettingsView.swift` | 保持自定义 prompt 功能，但默认 prompt 更新 |

### Markdown 渲染

AI 输出是 Markdown。用 `AttributedString(markdown:)` （macOS 14+ 原生支持）渲染基本格式（加粗、列表、代码）。不引入第三方依赖，零依赖原则不变。

如果原生 AttributedString 效果不够好，再考虑引入 swift-markdown-ui。

---

## 改动优先级

分两步实施：

### Phase 1: 核心体验（最小改动，最大感知变化）

1. **Prompt 改造** → AI 输出从"总结式"变为"洞察式"，返回 JSON
2. **触发逻辑** → 从定时定量改为 AI 自判断 + 节奏下限
3. **卡片 UI** → 气泡改卡片，加 📌
4. **三档模式** → 顶栏切换
5. **会话保存** → AI 信息流存 Markdown

### Phase 2: 体验打磨

6. **流式响应** → 打字机效果
7. **多轮对话** → 用户提问包含历史上下文
8. **上下文管理** → 滚动摘要，支撑长会议
9. **旧卡片折叠** → 信息流自动收起
10. **Markdown 渲染** → 支持加粗、列表等基本格式
