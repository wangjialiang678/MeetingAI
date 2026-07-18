---
title: "对话现场 AI 副驾 v2：核心问题复盘与下一版架构设计"
date: 2026-07-18
status: reviewed（2026-07-18 工作台评审通过，含修订：M0-M2 合并交付、弃本地模型、弃话轮触发、评估集不作门槛）
audience: both
tags: [design, rethink, realtime-copilot, v2]
---

# 对话现场 AI 副驾 v2：核心问题复盘与下一版架构设计

> 本文是对当前"会议中AI给建议"整体设计的从零复盘：先重新定义核心问题，再不受现有实现约束地推导解决方案空间，最后给出下一版迭代的推荐架构与迁移路径。
> 输入材料：现有代码与 openspec、`docs/research/2026-05-23-proactive-meeting-agent-private-board-coach.md`、2026-07-18 两份新调研（销售/教练实时 copilot 竞品刷新、实时对话 AI 架构最佳实践）、2026-07-18 用户口述需求。

## 1. 核心问题重新定义

### 1.1 用户口述需求还原（2026-07-18）

- 产品要解决的**不只是会议记录**。真实场景是各种"对话进行中"：销售与客户交流时 AI 给销售实时反馈和建议；教练与客户沟通时 AI 给教练建议。
- 现状痛点：大家都是**录音 → 转写 → 事后再跟 AI 讨论**。两个缺陷：① 没有实时性，洞察到手时对话已结束；② AI 洞察发生在另一个桌面/界面，要用户自己切过去、把上下文搬过去。
- 交互形态：**用户主动提问是基本盘**；AI 主动给建议是加分项，"主动的部分并不是必须的"。

### 1.2 核心问题的一句话表述

**在对话还能被改变的时候，把 AI 的认知能力送到对话现场、送到操作者眼前。**

拆开是三个子问题：

| 子问题 | 本质 | 失败形态 |
|---|---|---|
| P1 实时性 | 洞察必须落在"价值窗口"内到达——话题还活着、决定还没做、对方还在线 | 建议在话题翻篇之后才出现，等于没说 |
| P2 零搬运 | 上下文自动在场：AI 天然听着对话，用户提问不需要复述背景 | 用户要切窗口、粘贴转写、重新描述问题 |
| P3 低打扰 | 操作者正在对话中，注意力是最稀缺资源；AI 帮忙不能变成第二个要"应付"的参与者 | 卡片刷屏、长文、要求回应，反而降低对话质量 |

P1+P2 是与"录音+事后 AI 讨论"工作流的本质差异，是产品存在的理由；P3 是实时形态自带的约束条件。三者缺一不可：没有 P1/P2 就退化成 Otter/Granola；没有 P3 就是一个添乱的产品。

### 1.3 关键概念：价值半衰期决定延迟预算

从零推导时最重要的一个模型：**每一类 AI 介入都有自己的"价值半衰期"，系统的延迟预算必须按介入类型分层，而不是全局一个数**。

| 介入类型 | 典型场景 | 价值半衰期 | 可接受端到端延迟 |
|---|---|---|---|
| 应答式快查 | "PLG 是什么"；客户刚说的术语/数据是什么意思 | 当前话轮（秒级） | **≤ 3s 首字** |
| 时机型提示 | 客户抛出异议、教练客户说出关键信号、有人提出未验证假设 | 当前话题存活期 | **≤ 10s** |
| 结构型洞察 | 盲点、反方观点、决策框架、遗漏的利益相关方 | 当前议题（分钟级） | ≤ 60s |
| 阶段小结/复盘 | 话题切换、会议收尾、行动项汇总 | 阶段边界 | 1-3min 均可 |
| 深度调研 | 事实核实、竞品查证、背景调查 | 跨话题甚至会后 | 分钟级，带状态可见 |

当前实现的问题一眼可见：**所有介入共用一条"字数阈值触发 + 非流式 LLM"管线，实际端到端延迟 1-3 分钟**（触发等待占大头，LLM 10-50s），只能覆盖表格的后两行。而用户本次点名的销售/教练场景，价值恰恰集中在前两行。**这是本次复盘发现的最大结构性缺口。**

### 1.4 场景画像与 Jobs-to-be-Done

| 画像 | 对话形态 | 最想要的帮助 | 特殊约束 |
|---|---|---|---|
| 销售 | 1v1 或小group，客户拜访/电话，节奏快 | 异议应对提示、客户信号提醒、该问没问的发现性问题、下一步承诺是否拿到 | 延迟极敏感（异议窗口 10-30s）；错误建议的代价高于沉默；常在移动/线下 |
| 教练/咨询师 | 1v1，深度倾听为主，节奏慢但张力细腻 | 关键信号捕捉（情绪转折、限制性信念、目标漂移）、强有力提问建议、结构推进（如 GROW 阶段） | 教练自己要保持在场感，界面必须极简；隐私敏感度最高 |
| 会议主持人/参与者（现有场景） | 多人讨论 | 盲点、隐藏假设、过早共识、行动项完整性、阶段小结 | 多说话人；话题跳跃；会议长 |

三个画像共享同一条骨干（听→理解→按需/主动给建议→沉淀），差异全部集中在**"什么信号值得介入 + 用什么话术介入"**——这应当被抽象成可切换的**场景剧本（Scenario Playbook）**，而不是三个产品。

## 2. 现有设计盘点

### 2.1 架构现状（2026-07-18 代码事实）

```
麦克风 → AVAudioEngine 16k PCM → Go bridge(WS) → DashScope qwen3-asr 流式转写
  → 文本累积（字数/沉默阈值触发）→ MeetingContextBuilder（hot/近期/长期分层）
  → HTTP LLM（GLM-5.2 @ OpenRouter，非流式）→ shouldSpeak + 卡片 → 去重 → InsightFeedView
另有归档轨：分片 WAV → OSS → Fun-ASR 说话人分离 → GLM 逐分片交叉纠错 → 滚动回填 UI
```

### 2.2 值得保留的资产（复盘结论：这些没错，别推倒）

1. **本机旁听、不入会的形态**。不依赖 Zoom/Teams bot，线下面对面、电话、任何会议软件都能用——这恰好是销售拜访/教练面谈最常见的形态，也是与大多数竞品的差异点。
2. **评估与发言分离 + speaking budget + shouldSpeak 结构化输出**。openspec `clarify-active-meeting-copilot` 定义的这套控制面直接服务 P3，方向正确。
3. **双轨转写**（实时轻量 + 归档高质量带说话人）。"实时先可用、事后再精修"的思路与业界一致，且交叉纠错已跑通。
4. **分层上下文（hot window / 近期 / 长期）**。解决长对话 prompt 膨胀，继续沿用。
5. **`.events.log` 可观测性与产物落盘**。复盘判据齐全，v2 迭代的评估基础。
6. **卡片信任分级方向**（推测/转写证据/外部核实，openspec 已定义）。销售/教练场景中"错误建议代价高于沉默"，这套姿态更重要而非更不重要。
7. **按需发言三件套（shouldSpeak 结构化判断 + 洞察去重 + 分层上下文）是护城河**。2026-07-18 对两个直接对标的代码级拆解（见 5.3）确认：没有任何一个实现了这三件套——一个逢轮必答，一个靠自然语言 prompt 裸判断。不要向"总是响应"回退。

### 2.3 与核心问题的差距（按 P1/P2/P3 归因）

| # | 缺口 | 归因 | 说明 |
|---|---|---|---|
| G1 | 触发机制是"字数/沉默阈值"，不是"对话时刻" | P1 | 200 字 ≈ 1-2 分钟语音。异议出现、术语抛出、承诺缺失这类**语义事件**不会恰好落在字数边界上。触发延迟是端到端延迟的大头 |
| G2 | LLM 非流式、单模型单车道 | P1 | 10-50s 全量返回。没有"快车道"（秒级小模型/流式首字）与"深车道"（大模型综合）的分层 |
| G3 | 手动提问是二等公民 | P2 | 用户说主动提问是基本盘，但现在输入框藏在卡片流下方，没有全局热键、没有"针对刚才 30 秒"的快捷问法，回答也走同一条慢管线 |
| G4 | 单一通用"顾问"prompt，无场景剧本 | P1/P3 | 销售要异议库和发现性问题清单，教练要倾听信号和提问框架，现在只有一个泛化的会议顾问人格 |
| G5 | 卡片流 UI 假设用户有一块副屏注意力 | P3 | 对话进行中可用注意力是"扫一眼"级；缺少一行式 glanceable 呈现、可折叠详情、极简悬浮形态 |
| G6 | 无跨会/客户维度记忆 | P2 | 销售的客户历史、教练的个案历史是"上下文在场"的一部分，现在记忆只活在单次会话内 |
| G7 | 洞察质量无评估闭环 | 工程 | 5-23 调研就建议做离线评估集（模拟转写 + 人工标注"该说/不该说"），至今未做；触发器与 prompt 的迭代没有回归判据 |

## 3. 从零推导：解决方案空间

> 本节刻意不从现有代码出发，而从 1.3 的延迟分层模型出发，把设计空间按四个正交轴穷举，再组合出候选架构。

### 3.1 设计空间的四个轴

**轴 A：理解层吃什么**

| 选项 | 说明 | 直觉判断 |
|---|---|---|
| A1 级联 | 流式 ASR → 文本 → LLM（现状） | 文本是转写产物本身，一份投入两份产出；模型可自由换；可控性强 |
| A2 音频原生 | 实时多模态模型直接旁听音频流 | 理论延迟最低，能听到语气/情绪；但"持续旁听 + 默认沉默"不是这类 API 的设计姿态，成本与可控性存疑。**用户评审补充（2026-07-18）：多模态做不到实时、语气情绪短期意义也不大；它的真正价值是纠错——对置信度低的词所在句子及上下文几句，用多模态定向复听一遍**（归入归档轨演进方向） |
| A3 混合 | 文本骨干 + 关键片段送音频模型（语气/情绪补充） | 折中，复杂度最高 |

**轴 B：什么时候触发理解**

| 选项 | 说明 | 直觉判断 |
|---|---|---|
| B1 数量阈值 | 字数/时间/沉默（现状） | 实现简单，但与"对话时刻"错位，是 G1 的根源 |
| B2 话轮边界 | VAD/endpointing：每当一个人说完一段话 | **用户评审否决（2026-07-18）："实际使用时意义不大"**——不单设话轮触发源，语义扫描直接搭在转写流增量上 |
| B3 语义事件 | 便宜的持续扫描器识别：异议/提问/承诺/假设/话题切换/情绪转折 | 直接对准价值时刻；扫描器本身要够便宜够快 |
| B4 用户手动 | 全局热键/点击，"就现在，帮我看看" | 零误报，用户口述的基本盘；应是第一等公民 |

**轴 C：推理怎么分层**

| 选项 | 说明 |
|---|---|
| C1 单车道 | 一个模型包打天下（现状） |
| C2 双车道 | 快车道：小/快模型 + 流式输出，管 1.3 表前两行（≤10s）；深车道：大模型，管结构型洞察/小结/调研 |
| C3 三层 | 本地小模型初筛"值不值得说"→ 云端快车道 → 云端深车道。**用户评审否决（2026-07-18）："不考虑本地模型，也不用花太多时间在模型选择上，就用云端模型，以后再考虑多模型"** |

**轴 D：怎么呈现**

| 选项 | 说明 |
|---|---|
| D1 卡片流 | 现状；适合复盘，不适合对话中扫一眼 |
| D2 一行式 + 展开 | 首行独立传达价值（5-23 调研已建议），扫一眼 <1s，感兴趣再展开 |
| D3 极简悬浮条 | 常驻屏幕边缘的一行提示区，主窗口可最小化；销售/教练单屏场景关键 |
| D4 语音私播 | 耳机低声播报；侵入性最强，暂不考虑 |

### 3.2 候选架构组合

| 方案 | 组合 | 一句话 |
|---|---|---|
| 方案一：渐进强化 | A1 + B1→B2 + C1 + D2 | 现有管线加流式输出和话轮触发，改动最小 |
| 方案二：音频原生重构 | A2 + B3(模型内生) + C1 + D2/D3 | 推倒级联，实时多模态模型直接旁听 |
| 方案三：事件驱动双车道 | A1 + B2/B3/B4 并存 + C2(可演进 C3) + D2/D3 | ASR 骨干不动，触发层与推理层按价值半衰期分层重构 |
| 方案四：手动优先极简 | A1 + B4 only + C2 快车道 only + D3 | 砍掉全部主动性，热键即问即答做到极致 |

方案四不是独立终点，而是方案三的第一里程碑：先把"P2 零搬运 + 应答式快查 ≤3s"做扎实（这正是用户说的基本盘），主动性作为第二阶段在同一骨架上叠加。

## 4. 备选架构对比

| 评估维度 | 方案一 渐进强化 | 方案二 音频原生重构 | 方案三 事件驱动双车道 | 方案四 手动优先极简 |
|---|---|---|---|---|
| P1 实时性 | 部分改善（流式输出后感知 10-20s），仍无 ≤3s 快查 | 理论最优，实际存疑（Qwen2.5-Omni 实测首字 ~13s；商用 S2S 按轮流对话设计） | **全覆盖**：快车道 ≤3s 首字、时机提示 ≤10s、深车道保持现状 | 快查 ≤3s 覆盖，时机型/结构型缺失 |
| P2 零搬运 | 无改善（输入框仍是二等公民） | 同左 | **热键即问即答 + 场景上下文自动在场** | 同方案三（这就是它的全部） |
| P3 低打扰 | 无改善 | 更差（S2S 模型有"想说话"的倾向，抑制难） | 提示密度预算 + 场景剧本裁剪 + 一行式 UI | 最优（零主动输出） |
| 成本（8h/天） | 不变（~$100-200/月） | OpenAI Realtime $580-3,300/月；GLM-Realtime ~$360/月且 8K 上下文不够用 | 不变量级（快车道调用小模型，事件过滤反而减少全量分析次数） | 略降 |
| 技术风险 | 低 | 高（结构化输出弱、可控性差、噪声下准确率低于级联、供应商锁定） | 中（语义事件检测器命中率需评估集验证） | 低 |
| 现有资产复用 | 全部 | ASR/触发/上下文分层/speaking budget 全部报废 | **全部保留**，新增触发层与快车道 | 全部保留 |
| 结论 | 不够：没解决核心缺口 G1/G3/G4 | **否决**（证据见 5.2） | **推荐** | 作为方案三的第一里程碑 |

交互形态的旁证：直接对标产品 TalkPilot（商业）与 nicolelu/live-call-coaching（开源）都收敛到"热键/触发短语 + 屏幕共享不可见 overlay + 主动 tick 节流"的组合，与方案三/四的 B4+D3 判断一致。

## 5. 外部证据与反方观点

> 详细来源见 `docs/research/2026-07-18-realtime-sales-coach-copilot-refresh.md`（竞品/市场）与 `docs/research/2026-07-18-realtime-conversation-ai-architecture.md`（技术架构）。

### 5.1 市场与竞品证据（2026-07-18 刷新）

**赛道验证**：销售实时辅助已是成熟拥挤赛道——客服/电销侧有 Cresta、Balto、Observe.AI、Dialpad AI Live Coach；B2B 会议侧 Outreach Kaia、Clari Copilot 是真正会中实时（[Sybill 官方对比](https://www.sybill.ai/blogs/gong-vs-outreach)）。Cresta 2026-03 发布的 Knowledge Agent 已做到"无需人工触发、主动给带引用的答案"（[发布稿](https://www.prnewswire.com/news-releases/cresta-launches-knowledge-agent-an-agentic-assistant-delivering-proactive-intelligence-to-contact-center-workers-302715345.html)）。方向本身被市场持续验证，不是伪需求。

**差异化空间**：面向**教练本人**（executive coach / 私董会主持人）的会中实时 copilot 仍基本空白——CoachHub AIMY / BetterUp / Ovida 都服务被教练者或异步训练；唯一相邻形态 [Arcade AI Coach Co-Pilot](https://arcade.co/platform/ai-coaching) 面向销售经理 1:1 辅导，证明形态可行但未覆盖高客单价教练场景。中文市场的实时 AI 集中在电销合规话术（如中关村科金），未检索到对标产品（推测，检索覆盖有限）。

**直接对标**：[TalkPilot](https://www.talkpilot.co/)（Mac + 热键/触发短语 + 屏幕共享不可见）与开源 [nicolelu/live-call-coaching](https://github.com/nicolelu/live-call-coaching)（本地 Claude CLI 驱动、主动教练 tick + 会中提问）与本项目形态最接近，v2 设计前值得读其交互与节流实现。

**反方证据（≥5 独立信源）与结论**：

| 失败模式 | 证据 | 对 v2 的硬约束 |
|---|---|---|
| 延迟即死 | Balto 自曝：提示延迟 3 秒即侵蚀信任，采纳率一个月内崩溃（[Balto 博客](https://www.balto.ai/blog/how-agent-assist-ai-improves-customer-support)） | 时机型提示的**感知延迟上限 ≈3s**，这是采纳率的硬门槛，不是优化项——比本文 1.3 表格的预算更苛刻 |
| 泛化即忽略 | Balto：通用（未按场景调优）提示两周内被坐席忽略；Reddit 一线反馈"提示太多太啰嗦分散注意力，简化后才见效"（[r/salesdevelopment](https://www.reddit.com/r/salesdevelopment/comments/1ok20zp/we_tried_using_ai_to_help_reps_handle_objections)） | 场景剧本（G4）不是锦上添花；提示密度必须有预算；卡片必须一行传达价值 |
| 不迭代即衰减 | Calabrio：59% 呼叫中心上线后从不刷新 AI 训练；Sinch《2026 AI Production Paradox》：74% 已部署 AI 坐席 agent 被回滚（口径为 AI agent 整体，方向性参考）（[解读](https://aintelligencehub.com/articles/ai-agent-rollbacks-2026)） | 评估闭环（G7）升级为战略必需：无离线评估集就无法安全迭代触发器与 prompt |
| "用了"≠"融入" | Momentum.io 2026 报告：88% 团队声称用 AI，仅 24% 真正嵌入营收工作流（[Businesswire](https://www.businesswire.com/news/home/20260127999573/en/Momentum.io-Newest-2026-Voice-of-the-Market-Report-Finds-Most-AI-Adoption-Stops-Short-of-Revenue-Execution)） | 成功指标应是"建议被采纳/改变了对话行为"，不是"卡片产出量" |
| 隐身即反噬 | Cluely 从"Cheat on Everything"被迫转型 AI 会议助手，叠加 CEO 虚报 ARR 丑闻（[Inc.com](https://www.inc.com/leila-sheridan/an-a16z-backed-startup-that-helps-people-cheat-on-job-interviews-just-got-caught-in-a-7-million-lie-the-ceo-was-sweating/91313070)） | 继续坚持"本机私有、参会者知情、用户控制"，不拿"对方看不见"当卖点 |
| AI 反馈的边界 | Allego × 神经科学研究：AI 反馈提升 48h 记忆 50%，但动机/情绪投入/信任更依赖人类（[Allego](https://www.allego.com/news/allego-neuroscience-ai-coaching-study/)） | 产品定位是"放大操作者"而非替代其判断；教练场景中 AI 输出永远是给教练的私密参考 |

**综合判断**：外部证据没有否定"实时建议"方向，反而给出了成败分界线——**延迟、场景裁剪、提示密度、持续迭代**四个变量决定同一个功能是"副驾"还是"噪音"。这四个变量恰好对应第 2.3 节的 G1/G4/G5/G7。

### 5.2 技术架构证据（2026-07-18 调研）

**级联仍是 2026 年中生产级共识**（这直接否决方案二作主链路）：

- arXiv《Building Enterprise Realtime Voice Agents from Scratch》（2026-03）实测：原生 S2S（Qwen2.5-Omni）首字延迟约 13s，不适合实时；优化后的流式级联 P50 首字 947ms（最优 729ms），且是唯一支持成熟工具调用的层级（[arXiv 2603.05413](https://arxiv.org/pdf/2603.05413)）。
- arXiv《The Cascade Equivalence Hypothesis》（2026-03）：语音 LLM 内部本质是隐式 ASR→LLM 级联，噪声条件下显式级联准确率反而高出最多 7.6 个百分点（[arXiv 2602.17598](https://arxiv.org/html/2602.17598v2)）。
- LiveKit、Modulate、Gradium（Moshi 团队）三家厂商独立结论一致："2026 年生产环境默认级联，S2S 只在'自然度即产品'时优先"（[LiveKit](https://livekit.com/blog/realtime-vs-cascade)、[Gradium](https://gradium.ai/content/cascaded-voice-agent-vs-speech-to-speech-2026)）。
- **结构性错配**（推测，综合推理）：商用 S2S API（OpenAI Realtime / Gemini Live / GLM-Realtime / Qwen-Omni-Realtime）均按"单用户轮流对话"设计；用于"持续旁听多人、只偶尔吐文字卡片"需退化为纯转写模式——等于换了个更贵的 ASR 供应商，级联并未消除。GLM-Realtime 上下文仅 8K/约 2 分钟通话记忆，小时级会议不可用（[官方文档](https://docs.bigmodel.cn/cn/guide/models/sound-and-video/glm-realtime)）。
- **成本**：8h/天持续旁听，OpenAI Realtime 约 $580-3,300/月 vs 现有级联 ~$100-200/月，差 1-2 个数量级；唯一同量级的例外是 Gemini Flash Live"音频入/文字出"模式（~$70-150/月），但中文/多人质量未验证，只值得做 ASR 层候选 spike（[定价](https://ai.google.dev/gemini-api/docs/pricing)）。

**级联管线内部的提速手段是成熟的**（这支撑方案三的延迟目标可达）：

- 感知延迟优化组合拳：SSE 流式渲染、首个 partial 即路由、稳定前缀命中 prompt 缓存（GLM 缓存输入约 5.5 倍折扣）、短任务用小模型——叠加后对话式 agent 可做到 500-650ms p95（[FutureAGI](https://futureagi.com/blog/how-to-optimize-livekit-latency-2026)）。本项目 ≤3s 快查预算远比这宽松，**当前 10-50s 的瓶颈在触发机制和非流式生成，不在 ASR**。
- 语义 turn detection / 语义 VAD 已产品化（OpenAI `semantic_vad`；Speechmatics 用小型 SLM 做语义 turn detector），可直接迁移为本项目的"语义事件触发器"（[Speechmatics](https://blog.speechmatics.com/semantic-turn-detection)）。
- "小模型初筛 + 大模型按需接管"的路由模式业界成熟（RouteLLM 等），但**用于"会议中值不值得插话"无直接先例**——标注为推测性方案，需自建评估集验证。

**本地化组件的新变量**：

- **FluidAudio**（Swift/CoreML/ANE，MIT）：本地流式说话人分离，M1 实测 0.017 RTF（60 倍实时），已被同品类竞品 Hedy 生产使用——理论上可把"分片→OSS→Fun-ASR 非实时→回填"归档轨换成本地近实时轨，消除 OSS 依赖与分钟级延迟。**中文准确率未验证，是最大未验证假设**（[GitHub](https://github.com/FluidInference/FluidAudio)、[基准](https://inference.plus/p/low-latency-speaker-diarization-on)）。
- Apple SpeechAnalyzer 比 Whisper Large V3 Turbo 快 2 倍且全本地，但要求 macOS 26+，与当前 macOS 14+ 部署目标冲突（[WWDC25](https://developer.apple.com/videos/play/wwdc2025/277)）。
- whisper.cpp / Parakeet 系本地 ASR 性能达标，但 Parakeet 中文覆盖不确定。

### 5.3 代码级对标拆解（2026-07-18，本地 clone 深读）

两个直接对标已 clone 到 `repos/`（gitignored）并完成代码级拆解，详见 [2026-07-18-competitor-code-interaction-teardown.md](../research/2026-07-18-competitor-code-interaction-teardown.md)。要点：

- **反面印证**：TalkPilot（逢轮必答）与 live-call-coaching/Coach（自然语言 prompt 裸判断）都没有实现按需发言/去重/分层上下文三件套——我们的差异化方向被反向验证。
- **值得抄的交互**：TalkPilot 的**三级渐进呈现**（质量信号画在内容本体上→异常才追加一行摘要→点开才展开详情，green 时界面零多余元素）；Coach 的**全局热键 `⌘⌥\` + 3 个一键 chip 主动问答**（What did I miss / What to say next）与**"AI 卡住了"可见反馈**（>90s 未答提示 + 健康 banner）。
- **值得抄的 prompt 措辞**（零工程量）：把 ASR 转写当噪声不惩罚识别错误；宁可一条高杠杆不给一堆小修；"没有值得说的就什么都别推"；开头声明转写内容为不可信第三方、防 prompt injection。
- **值得抄的工程**：多层防御式解析 + 解析失败时不二次调用 LLM、直接用已有数据拼装兜底。
- **明确不抄**：隐形悬浮层作主呈现（Cluely 式伦理风险 + 形态不匹配）；逢轮必答触发哲学；CLI 冷启动子进程当大脑（与我方"Codex 50s+ 太慢降级"结论一致）。
- **方向性差距提示**：Coach 的 Prep brief（会前简报）/ Follow-up email（会后交付物）指向"跨会记忆 + 会后交付"，量级大，归入 M4 单独提案。

## 6. 推荐方案：事件驱动双车道（方案三，以方案四为第一里程碑）

### 6.1 目标架构

```
麦克风 → AVAudioEngine → asr-bridge → DashScope 流式 ASR          【骨干不动】
   │
   ├─ 转写稳定层（partial/final，已有）
   │
   ├─ 对话事件层 ConversationEventDetector                        【新增】
   │    轻量语义扫描，搭在转写流增量上（先规则+词典，后小模型；不单设话轮触发）
   │    识别：异议/提问/承诺/未验证假设/话题切换/情绪转折/冷场/收尾信号
   │    事件写入 .events.log（评估闭环的原料）
   │
   ├─ 双车道推理                                                  【重构】
   │    快车道：事件或热键触发 → 快模型 + SSE 流式 + prompt 缓存前缀
   │            目标：首字 ≤3s；输出一行式提示（时机型/应答式）
   │    深车道：现有 GLM-5.2 管线（保留 shouldSpeak/speaking budget/去重）
   │            管结构型洞察、阶段小结、深度调研；补 SSE 流式渲染
   │
   ├─ 场景剧本 Scenario Playbook                                  【新增】
   │    会前选择：销售 / 教练 / 会议 / 自定义
   │    注入：语义事件词典 + 介入类型白名单 + 话术风格 + 提示密度预算
   │
   ├─ 热键即问即答                                                【新增】
   │    全局热键唤起输入 + "针对最近 N 秒/当前话题"快捷上下文 → 快车道
   │
   └─ UI：一行式 glanceable 卡片（首行独立传达价值，点击展开）      【改造】
        可选极简悬浮条（主窗口最小化时仍可扫一眼）
        卡片流保留，转为复盘视图

归档轨：Fun-ASR 双轨保留；新增演进方向（用户提出，2026-07-18）：
        对低置信度词所在句子及上下文，用云端多模态模型定向复听纠错
        （与现有 TranscriptRefiner 文本交叉纠错互补；本地组件暂不考虑）
```

### 6.2 关键设计决策

| # | 决策 | 依据 |
|---|---|---|
| D1 | ASR 骨干与级联架构不动，否决音频原生重构 | 5.2 全部证据；现有资产全保留 |
| D2 | 触发源从"字数/沉默阈值"换为两类：语义事件（搭转写流增量）、全局热键（话轮边界触发经评审否决） | G1；Balto"延迟 3 秒即侵蚀信任"；用户 2026-07-18 评审认可 |
| D3 | 推理按价值半衰期分双车道，快车道流式首字 ≤3s | 1.3 模型；瓶颈实测在触发+非流式生成而非 ASR |
| D4 | 手动提问升为一等公民（全局热键 + 近窗上下文） | 用户口述"主动不是必须的"；TalkPilot/live-call-coaching 交互收敛佐证 |
| D5 | 场景剧本作为一等配置（销售/教练/会议） | G4；Balto"通用提示两周内被忽略" |
| D6 | 提示密度预算 + 三级渐进呈现（转写本体色标 → 一行摘要 → 点开详情） | G5；Reddit"简化后才见效"；TalkPilot 拆解验证"green 时零多余元素" |
| D7 | 离线评估集与语义触发器**并行建设，不作上线硬门槛**（原"先行门槛"方案用户评审存疑，已调整；上线后用真实会议 events.log 的采纳信号迭代） | G7；用户 2026-07-18 评审：存疑"评估集先行"，倾向直接做完 |
| D8 | 信任姿态延续：来源分级、参会者知情、不拿隐身当卖点 | openspec 已有方向 + Cluely 反例 |
| D9 | 快车道模型直接选一个云端快模型（config.json `ai.fastModel` 可配，默认走现有 OpenRouter），**不做选型项目**；实测延迟不达标再换配置 | 用户 2026-07-18 评审："不用花太多时间在模型选择上，就用云端模型，以后再考虑多模型" |

### 6.3 成功指标（对应反方证据的四个失败模式）

| 指标 | 目标 | 对应失败模式 |
|---|---|---|
| 快车道首字延迟 p50 | ≤3s（热键与时机型提示） | 延迟即死 |
| 时机型提示端到端（事件发生→卡片可见） | ≤10s | 延迟即死 |
| 提示密度 | 按模式预算（如顾问 ≤6 张/小时），超出即静默 | 泛化即忽略 |
| 卡片相关度/命中率 | 离线评估集上"该说"召回与"不该说"误报双指标，每次触发器/prompt 改动跑回归 | 不迭代即衰减 |
| 采纳信号 | pin/追问/采纳率随版本上升；纯产出量不作为指标 | "用了"≠"融入" |

## 7. 迁移路径与迭代切分

> **2026-07-18 评审结论：M0+M1+M2 合并为一个实施包一次交付**（用户："直接把需求都做完，不用分那么多 M"）。以下 M0-M2 条目即该实施包的内容清单；M3 为后续包（悬浮条已定延后）；M4 探索项大部分延后或取消（本地组件不考虑）。实施内部仍按"每个逻辑单元完成即验证"推进。

**M0 立即可做（纯优化，不改行为语义）**
- `AIEngine.swift`：HTTP 分析改 SSE 流式渲染；深车道卡片边生成边显示
- `MeetingContextBuilder.swift`：把 system prompt/固定说明整理为稳定前缀，验证 OpenRouter/GLM prompt 缓存命中（约 5.5 倍折扣）
- 分析 prompt 四改进（来自对标拆解，零风险）：ASR 噪声当前提、宁可一条高杠杆、没有就明说没有、injection 防御声明
- `AIEngine.swift` 解析容错：多层兜底 + 失败时用已有卡片拼装、不二次调用
- 验证：现有 P0/P1 smoke 全绿 + 新增流式解析 smoke

**M1 手动优先（= 方案四，交付 P2 + 应答式快查）**
- 全局热键唤起提问（macOS 辅助功能权限处理）；输入框支持"就刚才这段"快捷上下文（最近 N 秒话轮）
- 预置一键 chip（"就刚才这段"/"我漏了什么"/"下一步建议"）——参考 Coach 的 chip 交互，复用分析管线特化 prompt
- "AI 卡住了"可见反馈：分析发起/完成时间戳，超时在 feed 顶部提示（对标拆解确认我方此处空白）
- 快车道落地：`ai.fastModel` 配置 + 小型 benchmark 选型（首字 ≤3s 达标者入选）
- 一行式卡片改造 `InsightFeedView`/`Models.swift`（首行价值 + 展开）
- 验证：fixture E2E 加热键提问路径；真实 smoke 记录首字延迟分布

**M2 语义事件触发（P1 的时机型提示）**
- 离线评估集**并行建设、不作上线门槛**（评审调整）：先用 smoke 级模拟转写做基础回归，真实命中率靠 events.log 采纳信号迭代
- `ConversationEventDetector`：先规则+词典（每场景剧本自带），话轮边界触发扫描；事件写 `.events.log`
- 快车道接事件流，受提示密度预算约束；深车道触发条件同步从字数阈值迁移到事件/阶段边界
- 验证：评估集回归 + 真实彩排对比（触发次数、命中率、延迟）

**M3 场景剧本 + 呈现升级**
- Playbook 配置模型（销售/教练/会议内置 + 自定义）：事件词典、介入白名单、话术风格、密度预算；`SettingsView` 选择入口
- 极简悬浮条（可选开启）；卡片流转复盘视图
- 教练/销售剧本内容设计参考：5-23 报告私董会 taxonomy 方法 + Arcade/Outreach battlecard 机制

**M4 探索项（评审后调整）**
- ~~FluidAudio 中文说话人分离基准~~ / ~~SpeechAnalyzer~~：**取消**（用户决策：不考虑本地模型/组件）
- ~~Gemini Flash Live spike~~：**延后**（不花时间做模型选型，以后再考虑多模型）
- **新增（用户提出）**：低置信度定向复听纠错——对置信度低的词所在句子及上下文几句，把对应音频片段送云端多模态模型复听一遍，与 TranscriptRefiner 文本交叉纠错互补（归档轨已有分片 WAV，工程上具备条件；待单独排期）
- 跨会/客户维度记忆（销售客户历史、教练个案历史）——进入 openspec 单独提案；形态参考 Coach 的 Prep brief（会前简报）与 Follow-up（会后交付物），前置依赖 sessions 索引基础设施

落地方式（评审后）：直接实施合并包，openspec change（建议名 `realtime-copilot-v2`）随实施补录，与既有 `clarify-active-meeting-copilot`（speaking budget/研究队列/信任分级）合并演进，不冲突。

## 8. 风险与开放问题

### 8.1 风险

| 风险 | 缓解 |
|---|---|
| 语义事件检测器误报多 → 提示噪音（最大产品风险） | M2 前置离线评估集；密度预算硬约束；先规则后模型，逐步放开 |
| 快车道小模型输出质量不稳 | benchmark 选型 + 快车道只做短提示/快查，结构型洞察仍走深车道 |
| FluidAudio 中文准确率不达标 | spike 先行，不动生产链路；Fun-ASR 轨保留兜底 |
| 全局热键/悬浮窗涉及系统权限与窗口层级坑 | M1 单独排期处理权限引导；参考 TalkPilot/live-call-coaching 实现 |
| 三场景摊薄精力，剧本内容空洞 | 先做透一个场景（见 8.2 问题 1），其余复用骨架 |
| 触发器/prompt 一次调好后价值衰减 | 评估集回归纳入 tests/run-all.sh 流程；采纳信号进 events.log 长期跟踪 |

### 8.2 开放问题与评审结论（2026-07-18 工作台评审，session `meetingai-v2-review`）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 首发场景选哪个？ | **未表态**。处理：剧本机制先行，三个场景做轻量内置预设（默认=会议，延续现状），内容深化待用户后续指定 |
| 2 | 评审后节奏 | **一次做完**："直接把需求都做完，不用分那么多 M"——M0+M1+M2 合并交付 |
| 3 | macOS 最低版本 | 未表态；本地组件已整体不考虑，此题暂失效，维持 14+ |
| 4 | 快车道模型 | 不做选型项目，直接用云端快模型（config 可换），以后再考虑多模型 |
| 5 | 悬浮条 | **延后**（M3 之后再议），先用主窗口验证内容质量 |
| — | 九条设计决策 | D1-D6、D8、D9 认可；D7 存疑 → 已调整为"评估集并行、不作门槛" |
| — | 整体方向 | 未单独表态，但逐条决策 8/9 认可 + 指示直接开工，视为方向通过 |
| — | 新增需求（用户提出） | 多模态模型用于低置信度片段定向复听纠错（见 M4 新增项） |

既有 openspec 开放问题继续有效（快查是否自动执行、调研任务是否跨会存活等）。

## 参考来源

完整来源清单见两份调研报告：

- [2026-07-18 实时销售/教练 AI Copilot 赛道刷新](../research/2026-07-18-realtime-sales-coach-copilot-refresh.md)（竞品、市场、反方证据，含 40+ 来源）
- [2026-07-18 实时对话理解+建议架构调研](../research/2026-07-18-realtime-conversation-ai-architecture.md)（架构、延迟、成本、本地组件，含 20+ 来源）
- [2026-05-23 Proactive Meeting Agent 与私董会实时 AI 教练调研](../research/2026-05-23-proactive-meeting-agent-private-board-coach.md)（HCI 论文、卡片 taxonomy、产品原则）
- [2026-07-18 竞品代码/交互级拆解：TalkPilot & live-call-coaching](../research/2026-07-18-competitor-code-interaction-teardown.md)（本地 clone 深读，交互与 prompt 借鉴清单，仓库在 `repos/`）

正文关键声明的直接来源（多源交叉验证项标注 ✓✓）：

- 级联 vs S2S 共识 ✓✓：[arXiv 2603.05413](https://arxiv.org/pdf/2603.05413)、[arXiv 2602.17598](https://arxiv.org/html/2602.17598v2)、[LiveKit](https://livekit.com/blog/realtime-vs-cascade)、[Gradium](https://gradium.ai/content/cascaded-voice-agent-vs-speech-to-speech-2026)
- 延迟/采纳硬约束 ✓✓：[Balto](https://www.balto.ai/blog/how-agent-assist-ai-improves-customer-support)、[Reddit r/salesdevelopment](https://www.reddit.com/r/salesdevelopment/comments/1ok20zp/we_tried_using_ai_to_help_reps_handle_objections)
- 部署后衰减/回滚 ✓✓：[Sinch 报告解读](https://aintelligencehub.com/articles/ai-agent-rollbacks-2026)、[Momentum.io](https://www.businesswire.com/news/home/20260127999573/en/Momentum.io-Newest-2026-Voice-of-the-Market-Report-Finds-Most-AI-Adoption-Stops-Short-of-Revenue-Execution)
- 教练细分空白（推测，非穷尽检索）：[Arcade](https://arcade.co/platform/ai-coaching)、[CoachHub AIMY](https://www.coachhub.com/aimy)、[Ovida](https://www.ovida.org)
- 直接对标交互形态：[TalkPilot](https://www.talkpilot.co/)、[nicolelu/live-call-coaching](https://github.com/nicolelu/live-call-coaching)
- 本地说话人分离：[FluidAudio](https://github.com/FluidInference/FluidAudio)
- Cluely 反例：[Inc.com](https://www.inc.com/leila-sheridan/an-a16z-backed-startup-that-helps-people-cheat-on-job-interviews-just-got-caught-in-a-7-million-lie-the-ceo-was-sweating/91313070)、[Wikipedia](https://en.wikipedia.org/wiki/Cluely)
