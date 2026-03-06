# 调研报告: LLM Agent 记忆/上下文压缩算法

**日期**: 2026-02-27
**任务**: 调研适合会议实时转写 App 的上下文压缩策略，重点关注实用、低复杂度、可直接落地的方案

---

## 调研摘要

会议转写场景属于"单会话、单向追加、有时间维度"的长文本场景，与通用对话记忆不完全相同。最适合的方案是 **分层增量压缩（Tiered Incremental Summarization）**，核心思路与 LangChain 的 ConversationSummaryBufferMemory 一致，但简化为"原文窗口 + 固定摘要缓存"两层，无需复杂框架依赖，直接在 Swift 层实现即可。

---

## 各方案分析

### 1. MemGPT / Letta 虚拟上下文管理

**核心机制**:
MemGPT 借鉴操作系统的分层内存模型，将记忆分为三层：
- **Core Memory**（始终在上下文中）：精简的角色定义、用户关键信息
- **Recall Memory**（外部可搜索）：完整对话历史，按时间戳/语义检索
- **Archival Memory**（长期存储）：经过整理的知识，通过向量搜索召回

LLM 自主决定何时调用工具把信息从外部存储搜索进上下文（类似操作系统的页面换入）。

**对本项目的适用性**: 低
MemGPT 设计用于长期持久化 Agent（跨会话记忆），需要向量数据库、嵌入模型。本项目无持久化需求，会议结束即丢弃，这套架构过重。唯一可借鉴的是"Core Memory 始终在上下文"的思路，即始终保留一个压缩后的会议摘要块。

---

### 2. LangChain Memory 系列

**ConversationBufferMemory**
- 把所有历史原文塞进上下文，简单但 token 无限增长
- 适合短对话，不适合长会议

**ConversationBufferWindowMemory**
- 只保留最近 K 条消息的原文，丢弃更旧的
- 简单，但早期讨论的上下文完全丢失

**ConversationSummaryMemory**
- 维护一个滚动摘要，每次新消息都更新摘要，没有原文保留
- 摘要精度受限，且每次都需要调用 LLM 更新（实时性差）

**ConversationSummaryBufferMemory（最相关）**
- 混合策略：最近 N token 保留原文，超出阈值的旧内容压缩为摘要
- 核心公式：`context = running_summary + recent_verbatim_buffer`
- 触发条件：buffer token 超过 max_token_limit 时，把最旧的若干条消息压缩进 summary，然后从 buffer 删除
- 增量更新：`new_summary = LLM(existing_summary + expired_messages)`，不重新压缩整个历史

**对本项目的适用性**: 高（ConversationSummaryBufferMemory 思路）
这个方案的核心思路直接对应你们的分层设计：recent buffer（最近 10 分钟原文）+ summary（历史压缩摘要）。差异只是边界条件用时间而不是 token 数来划分。

---

### 3. 滑动窗口 + 渐进压缩（Hierarchical Tiered Summarization）

**核心机制**:
维护多个时间层，每层有不同的压缩比：
```
T_now - 10min:  原文（0% 压缩）
10min - 30min:  AI 摘要（~50% 压缩）
30min+:         高度浓缩摘要（~80% 压缩）
```
每次 AI 分析触发时，检查每个时间窗口是否有新内容需要压缩。

**工业界类似实践**:
- Anthropic 的 Claude.ai 长对话模式用类似分层压缩
- JetBrains 研究团队（2025.12）实现了"selective context retention"
- LLMLingua 等工具通过 token 重要性评分实现 10:1 压缩率（但需要单独模型）

**对本项目的适用性**: 高，且与你们的既有设计高度一致

---

### 4. 增量摘要缓存策略（避免重复压缩）

**核心思路**:
不是每次触发分析都重新生成摘要，而是：
1. 维护一个持久化的摘要缓存，记录"已摘要到哪个 TranscriptEntry"
2. 下次触发时，只把"未摘要的新增内容"追加进去，更新摘要
3. 公式：`new_summary = LLM("基于已有摘要，追加整合以下新内容：" + new_chunks)`

**效率对比**:
- 朴素方案：每次发送全量历史给 AI 压缩 → O(n) token 消耗
- 增量缓存：每次只发送增量内容 → O(delta) token 消耗
- 适合会议场景：内容单向追加，天然适合增量更新

**对本项目的适用性**: 高，是最重要的效率优化点

---

### 5. 主动上下文压缩（Focus Agent 模式）

**核心机制**:
LLM 在执行过程中自主决定何时压缩，通过 `start_focus/complete_focus` 检查点对标记的历史段落进行"打包摘要+删除原文"。

论文（arxiv 2601.07190）显示：
- 在 SWE-bench 上实现 22.7% token 减少，任务成功率不变
- 但需要显式 prompt 工程驱动（"每 10-15 次工具调用压缩一次"），LLM 不会自动做这件事

**对本项目的适用性**: 低
这个方案面向多步骤 Agentic 任务（反复工具调用），不适合本项目的"定时分析广播"场景。概念可以借鉴（让 AI 系统消息中明确被告知当前内存状态），但不需要实现这套机制。

---

## 推荐方案

**推荐：分层增量压缩（Tiered Incremental Summarization）**

直接延伸你们现有的分层设计，加入增量缓存机制。

### 具体设计

```
数据结构：
- transcriptEntries: [TranscriptEntry]   // 全量原文（带时间戳）
- summaryCache: SummaryCache             // 摘要缓存

SummaryCache {
    lastSummarizedIndex: Int  // 已处理到第几条 entry
    mediumSummary: String     // 10-30 分钟段的最新摘要
    longSummary: String       // 30 分钟以上段的最新摘要
    updatedAt: Date
}
```

```
每次 AI 分析时，构建 context：
1. recent_verbatim = transcriptEntries where timestamp > now-10min（原文）
2. medium_verbatim = transcriptEntries where timestamp in [now-30min, now-10min]
3. long_verbatim   = transcriptEntries where timestamp < now-30min

构建分析请求：
context = {
    "会议历史摘要（30分钟前）": summaryCache.longSummary,
    "近期讨论摘要（10-30分钟）": summaryCache.mediumSummary,
    "最近发言（原文）": recent_verbatim
}
```

```
摘要更新策略（增量）：
触发条件：medium/long 层有新内容进入（即有 entry 的 timestamp 超过了边界）

更新 medium_summary：
  new_entries = entries[lastMediumIndex ..< newBoundaryIndex]
  if new_entries 非空：
    prompt = "现有摘要：{mediumSummary}\n新增内容：{new_entries}\n请更新摘要"
    mediumSummary = await ai.summarize(prompt)
    lastMediumIndex = newBoundaryIndex

更新 long_summary：同理，但触发频率更低（每 5-10 分钟检查一次即可）
```

---

## 实施建议

### 关键步骤

1. **定义 SummaryCache 结构体**（Swift）
   - 包含 `lastMediumIndex`、`lastLongIndex`、`mediumSummary`、`longSummary`
   - 纯内存，不持久化（符合 MVP no-persistence 要求）

2. **实现 buildContext() 方法**
   - 输入：`[TranscriptEntry]`、`SummaryCache`、`Date`（当前时间）
   - 输出：组装好的 prompt 上下文字符串
   - 分三段：longSummary + mediumSummary + recent 原文

3. **实现 updateSummaryIfNeeded() 方法**
   - 在每次 AI 分析触发前调用
   - 只处理"新移出 recent 窗口"的 entries
   - 增量 prompt：`"在以下已有摘要基础上，整合新增发言内容："`

4. **配置 token 预算**（可选优化）
   - recent 原文：保留完整，但设上限（如最多 2000 token ≈ 3-4 分钟发言）
   - medium summary：目标 300-500 token
   - long summary：目标 200-300 token
   - 总上下文预算：~1500 token（远低于 MiniMax M2.5 的 100K 限制）

5. **单独的"摘要 API 调用"与"分析 API 调用"分离**
   - 摘要更新（后台，低优先级）：使用更快/便宜的 mini 模型
   - 分析推送（前台）：使用主模型

### 风险点

- **摘要漂移**：多次增量更新可能导致摘要偏离原意
  - 缓解：每 30 分钟对 longSummary 做一次全量重压缩（因为此时 long 层内容已经稳定）

- **边界条件**：会议刚开始（< 10 分钟）时 summary 为空
  - 缓解：summaryCache 初始为空字符串，buildContext 时跳过空摘要段落

- **摘要更新延迟影响分析质量**：如果摘要更新本身耗时，分析可能基于旧摘要
  - 缓解：可以让摘要更新异步，但分析等待其完成（或接受旧摘要作为 fallback）

### 依赖项

- MiniMax M2.5 API（已有，复用）
- 无新增第三方库
- 仅需在现有 `AIEngine` 中增加一个 `SummaryCache` 状态和两个方法

---

## 对比总结

| 方案 | 实现复杂度 | token 效率 | 信息保留质量 | 适用性 |
|------|-----------|-----------|------------|--------|
| 全量原文传递 | 极低 | 很差（线性增长）| 完美 | MVP 快速验证用 |
| 只传最近 N 分钟 | 低 | 好 | 差（丢历史）| 不推荐 |
| 一次性 AI 压缩（每次触发重压）| 低 | 中（每次都重压）| 中 | 可作 fallback |
| **分层增量压缩（推荐）** | 中 | 很好（增量更新）| 好 | 推荐 |
| MemGPT 完整方案 | 高 | 极好 | 很好 | 过重 |

---

## 参考资料

- [MemGPT: Towards LLMs as Operating Systems (arxiv)](https://arxiv.org/abs/2310.08560)
- [MemGPT 官方文档 - Letta](https://docs.letta.com/concepts/memgpt/)
- [LangChain ConversationSummaryBufferMemory](https://python.langchain.com/api_reference/langchain/memory/langchain.memory.summary_buffer.ConversationSummaryBufferMemory.html)
- [Context Window Management Strategies (Maxim)](https://www.getmaxim.ai/articles/context-window-management-strategies-for-long-context-ai-agents-and-chatbots/)
- [Active Context Compression: Focus Agent (arxiv 2601.07190)](https://arxiv.org/html/2601.07190)
- [Acon: Optimizing Context Compression (arxiv)](https://arxiv.org/html/2510.00615v2)
- [JetBrains: Efficient Context Management (2025.12)](https://blog.jetbrains.com/research/2025/12/efficient-context-management/)
- [LLM Chat History Summarization Guide (mem0.ai)](https://mem0.ai/blog/llm-chat-history-summarization-guide-2025)
- [Enhancing Incremental Summarization with Structured Representations (arxiv)](https://arxiv.org/html/2407.15021v1)
