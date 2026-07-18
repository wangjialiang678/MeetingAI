---
title: 实时销售/教练 AI Copilot 赛道刷新调研（2026-05 至今）
date: 2026-07-18
status: active
audience: both
tags: [research, real-time-copilot, sales-assist, coaching, cluely, agent-assist]
type: 原始调研
sources: [tavily, exa, baidu, brave]
verified: 2026-07-18
shelf_life: 快速变化
---

# 调研报告: 实时销售/教练 AI Copilot 赛道刷新（2026-05 至今）

**日期**: 2026-07-18
**任务**: 在已有的 [2026-05-23 私董会实时 AI 教练调研](./2026-05-23-proactive-meeting-agent-private-board-coach.md) 基础上，补齐两个盲区（销售实时辅助赛道、教练本人的实时 copilot）、刷新 2026 年 5 月下旬以来的市场变化，并收集"实时 AI 建议"在真实场景中失败/被弃用的反方证据。

---

## 调研摘要

1. **销售实时辅助（contact-center agent assist + 销售会中 copilot）已是成熟且拥挤的赛道**，Cresta、Balto、Observe.AI、Five9、Google Cloud Agent Assist、Dialpad AI Live Coach 主打客服/电销场景；Attention、Sybill、Clari Copilot、Outreach Kaia、Zoom Revenue Accelerator、Salesforce Agentforce 主打 B2B 销售会议场景。但**"实时"内涵参差不齐**：不少产品把"实时"用于电销/客服脚本合规提示，真正逐句响应异议的、真正会中双向问答的产品仍是少数（Balto、Cresta、Dialpad、Clari Copilot、少量新创如 SalesGhost/Redix/LiveSuggest/Manja/TalkPilot）。
2. **教练（coach）本人使用的会中实时 copilot 存在明确细分空白**：CoachHub AIMY、BetterUp、Ovida 等产品的 AI 都是面向"被教练者"或"教练的练习/训练场景"（异步、录像回看、角色扮演），没有发现面向执行教练/生活教练本人、在真实付费客户会话进行中给教练实时提示的产品。**唯一确认的相邻形态**是 [Arcade AI Coach Co-Pilot](https://arcade.co/platform/ai-coaching)——但服务对象是"一线销售经理对下属做 1:1 辅导"，不是执行教练/私董会场景。这一细分（私董会/executive coaching 教练本人的实时智囊）仍基本空白（推测，基于未能检索到反例，非穷尽性证据）。
3. **Cluely 是本轮最大的负面案例**：2026 年 3 月被 TechCrunch 曝光 CEO Roy Lee 虚报 ARR（声称 700 万美元，后承认约 520 万美元"fractionally wrong"），叠加"Cheat on Everything"发布视频的持续伦理争议，公司已被迫从"作弊神器"定位转向"AI 会议助手"，与 Otter/Granola/Fireflies 正面竞争同一预算科目。这验证了上一份报告"不建议把隐形/不可见作为核心卖点"的判断。
4. **2026 年新出现了一批和本项目定位高度相似的小型实时会中 copilot 创业产品**：TalkPilot（Mac + AirPods + 热键、屏幕共享不可见、触发短语）、SalesGhost（Mac+Windows 原生、宣称"唯一真正实时"）、Redix AI、LiveSuggest、Manja AI、Spiked.ai（"认知过载"叙事）、7Q.ai（NEPQ 方法论实时化）。这些多为早期/自证式营销内容，需要谨慎验证真实用户规模。
5. **反方证据充分且来自≥5 个独立信源**：Balto/Cresta 自己的博客承认"提示延迟 3 秒就会侵蚀信任，采用率一个月内崩溃""通用提示两周内被忽略"；Calabrio 数据显示 59% 的呼叫中心从不刷新 AI 训练；Sinch 2026《AI Production Paradox》报告显示 74% 的已部署 AI 客服/坐席 agent 被回滚或下线（治理成熟组织中回滚率反而升到 81%）；Momentum.io《2026 Voice of the Market》报告发现 88% 团队声称采用了 AI，但只有 24% 真正嵌入营收工作流；Reddit r/salesdevelopment 一线运营者的原始反馈是"提示太多太啰嗦，团队被分散注意力，简化后才见效"；Allego 与神经科学家 Carmen Simon 合作的脑电/生理研究发现，AI 反馈提升记忆（48 小时后多记住 50% 内容）但显著降低学员的情绪投入和动机，人类观察会让销售代表说话更多但记得更少。这些共同指向："实时/AI建议"本身不是失败点，**触发延迟、提示密度、缺乏情境裁剪、组织未同步做变更管理**才是失败点。

---

## 一、销售实时辅助赛道现状（2026 年中）

### 1.1 客服/呼叫中心 Agent Assist（偏电销/客服场景）

| 产品 | 触发机制 | 延迟/UI 形态 | 采纳/效果证据 | 来源 |
|---|---|---|---|---|
| [Cresta Agent Assist / Knowledge Agent](https://cresta.com/guides/agent-assist-what-it-is-how-it-works-how-to-choose) | 全程监听会话，基于自家客户对话训练的模型判断何时给"精确答案/行动导向提示" | 浏览器侧边栏，2026 年 3 月新发布 Knowledge Agent 主动无需人工触发给答案 | Cox 案例：营收+20%、管理跨度+40%；坡道期缩短 30%（vendor 自报） | [Cresta 客户案例](https://cresta.com/guides/conversational-ai-call-center) |
| [Balto](https://www.balto.ai/blog/how-agent-assist-ai-improves-customer-support) | 实时脚本/合规提示、异议处理 | 屏幕内嵌卡片；2026 路线图加入 RAG 驱动的 Agent Assist、AI Notes、更早期风险 QA | **自曝弱点**：提示延迟 3 秒/丢失会在一个月内让"采纳率崩溃"；通用（非按最佳坐席调优的）提示会在两周内被坐席忽略 | [Balto 官方博客](https://www.balto.ai/blog/how-agent-assist-ai-improves-customer-support) |
| [Observe.AI Engage](https://thelevel.ai/blog/top-balto-alternatives-and-competitors-in-2026) | 先做会后 QA 起家，后补实时能力 | 实时知识提示+ QA 打分闭环 | 定位"post-call 起家，实时是后加的" | Level AI 竞品对比 |
| [Five9 Genius Agent / Google Cloud Agent Assist / Dialpad AI Live Coach](https://www.dialpad.com/features/ai-live-coach) | 平台内置，转写+知识库检索 | 原生嵌入呼叫平台，不需要额外工具 | Dialpad 明确定位"多数教练工具是会后分析，AI Live Coach 是会中" | Dialpad 官网 |

**行业级采纳数据**（2026）：88% 的呼叫中心报告"使用某种 AI"，但**只有 25% 完成了全面集成**；McKinsey 报告 AI 部署使总互动量下降 40–50%；Gartner 预测超 80% 的组织计划在未来 18 个月削减坐席编制，但 84% 也在给坐席"加新技能"。[Lorikeet 30 项统计](https://www.lorikeetcx.ai/articles/ai-customer-service-statistics) / [Gartner 2026 新闻稿](https://www.gartner.com/en/newsroom/press-releases/2025-12-17-customer-service-and-support-leaders-must-prioritize-blending-human-strengths-with-ai-intelligence-in-2026)

### 1.2 B2B 销售会议场景的实时/近实时 copilot

| 产品 | 2026 现状 | 是否真正"会中实时" | 来源 |
|---|---|---|---|
| [Attention](https://tldv.io/blog/attention-alternatives) | 会中异议处理建议+battlecard，主打 scorecard/自动化 | 中（有会中能力，但更强在会后自动化 CRM） | tldv 对比评测 |
| [Sybill](https://www.sybill.ai/blogs/gong-vs-outreach) | 定位"deal copilot"，核心卖点是会后 CRM 自动填写、pre-meeting brief | 弱（官方自己承认"Gong 是回顾式、Outreach Kaia 才是实时"） | Sybill 官方博客自我定位 |
| [Outreach Kaia](https://www.sybill.ai/blogs/gong-vs-outreach) | 会中 battlecard、实时 coaching cue | 强 | 同上 |
| [Clari Copilot](https://demodesk.com/blog/zoom-revenue-accelerator-alternatives) | 实时 battlecard、monologue 提醒、revenue leak 检测 | 强 | Demodesk 竞品对比 |
| [Zoom Revenue Accelerator](https://tldv.io/blog/zoom-iq-for-sales) | 2026 年新增"real-time playbook alignment、objection detection、自动化 scorecard"，但深度仍不及专项工具 | 中（自认"还没有超个性化会中低语"，2027 规划中） | tldv 深度评测 |
| [Salesforce Agentforce](https://vantagepoint.io/blog/sf/the-complete-guide-to-salesforces-agentforce-ecosystem-understanding-the-full-product-portfolio-in-2026) | 定位是 CRM 内的自主 agent（预测/报价/CRM更新），"real-time sales insights"更多是数据面而非会中语音建议 | 弱到中 | Vantage Point Agentforce 指南 |

### 1.3 2026 年新出现的小型"实时会中 copilot"创业产品（多为早期，需谨慎验证）

这批产品与本项目定位高度重叠（Mac 桌面、屏幕共享不可见、会中侧栏），值得重点关注：

- [SalesGhost](https://salesghost.app/blog/real-time-ai-sales-coaching-guide-2025)：宣称"Mac+Windows 原生、双流转写、基于自有知识库回答"，博客体系整站自我定位为"唯一真正实时"的对比文（**内容高度自证营销化，需谨慎核实真实用户规模**）。
- [Redix AI](https://redixai.com/real-time-sales-coach)：屏幕共享不可见 overlay + "私密双向 AI 对话通道"（会中可以直接向 AI 提问，对方听不到）。
- [LiveSuggest](https://livesuggest.ai/sales-meetings/)：浏览器侧窗口、无 bot 入会、会话结束即删除音频。
- [Manja AI](https://manja.ai/live_coaching.html)：面向 AE Demo 场景，支持"经理静默观察 + 会中发消息教练 AE"。
- [Spiked.ai](https://www.youtube.com/watch?v=_sGoKbIOLAc)：定位"认知革命智能层"，核心叙事是"顶尖销售和普通销售的差距是认知负荷差距"，预测买家下一个问题并提前喂答案。
- [7Q.ai](https://www.linkedin.com/posts/agaton-ai_...)：把 Jeremy Miner 的 NEPQ 销售方法论做成会中实时问题建议。
- [TalkPilot](https://www.talkpilot.co/)：**与本项目形态最接近**——Mac / iPhone / AirPods 均可触发，热键或触发短语（如说"let me think…"）即弹出建议，屏幕共享/录制不可见；场景覆盖销售、面试、约会、呼叫中心合规提示，还提供"Solo Practice"角色扮演。
- [nicolelu/live-call-coaching](https://github.com/nicolelu/live-call-coaching)（开源 GitHub 项目）：用 Claude Code CLI 作为"大脑"，屏幕共享不可见的会中教练卡片，支持主动教练 tick 和会中提问，是目前检索到的**架构上最接近本项目**的开源实现（本机驱动本地 `claude` CLI，非云端 API key 计费）。

---

## 二、教练（coaching）场景实时 AI：细分空白确认

### 2.1 面向"被教练者"的产品（明确不是本项目要找的方向）

- [CoachHub AIMY](https://www.coachhub.com/aimy)：员工/被辅导对象的 24/7 AI 教练，独立于人类教练会话之外。
- [BetterUp](https://arahi.ai/blog/best-ai-coaching-tools)：结构化反思问题+行为分析，服务对象也是被教练者。
- [Ovida](https://www.ovida.org)：**面向教练的培训场景**，但核心用途是"教练在录像/角色扮演后获得 ICF 胜任力打分反馈"，是异步的技能训练工具，不是教练在真实付费客户会话进行时使用的实时助手。

### 2.2 唯一确认的相邻形态

[Arcade AI Coach Co-Pilot](https://arcade.co/platform/ai-coaching)：定位是"一线销售经理和下属做 1:1 辅导时的实时 AI 支持"——监听真实的经理-员工 1:1 对话，实时告诉经理"接下来该问什么、该强化什么"，并自动生成辅导小结。这证明"教练本人的实时 copilot"这一产品形态**技术上可行且已有厂商在做**，但目标客户是企业内部的销售管理场景，不是 executive coach / life coach / 私董会主持人。

### 2.3 结论（推测，非穷尽检索）

在检索范围内没有发现面向 executive coach / life coach / 私董会 chair 本人、在真实客户会话进行中给出实时提示的独立产品。这与 5 月报告的判断一致：**这个细分仍然基本空白**，Arcade 的存在说明技术和商业模式已被验证可行，只是尚未有人把它对准"高价值一对一/私董会教练"这个更窄、更高客单价的群体。

---

## 三、2026 年 5 月下旬以来的关键变化

### 3.1 Cluely：负面案例升级

- 2026 年 3 月 5–6 日，Cluely 联合创始人兼 CEO Roy Lee 被 TechCrunch 曝光此前公开虚报年化经常性收入（ARR）：曾宣称 700 万美元，后承认真实数字约为 520 万美元，称是"fractionally wrong"。[TechCrunch via Inc.com](https://www.inc.com/leila-sheridan/an-a16z-backed-startup-that-helps-people-cheat-on-job-interviews-just-got-caught-in-a-7-million-lie-the-ceo-was-sweating/91313070)
- Wikipedia 词条确认公司延续 2025 年末的转型：从"Cheat on Everything"逐步淡化措辞，2026 年正式以"AI 会议助手"身份与 Otter/Granola/Fireflies 争夺同一预算科目。[Cluely - Wikipedia](https://en.wikipedia.org/wiki/Cluely)
- 第三方增长复盘（Postbeam）认为这次重新定位是刻意的商业策略：作弊工具很难走企业报销流程，"AI 会议记录+洞察"是买家已经有预算的品类，因此更容易被财务批准、流失率更低。[Postbeam GTM 复盘](https://www.postbeam.ai/blog/how-cluely-grows)
- tldv 的深度评测指出：延迟在"最高压力时刻"反而更差，且 Reddit 上仍有用户公开讨论用它在面试中"作弊"，伦理争议并未随定位转型消失。[tldv Cluely 评测](https://tldv.io/blog/cluely-review)

### 3.2 Cresta / Balto 等头部厂商的 2026 产品动作

- Cresta 于 2026 年 3 月发布 Knowledge Agent：**无需人工触发**、主动把"听到的+屏幕上看到的"关联起来直接给出带引用的答案。[PR Newswire](https://www.prnewswire.com/news-releases/cresta-launches-knowledge-agent-an-agentic-assistant-delivering-proactive-intelligence-to-contact-center-workers-302715345.html)
- Balto 公布 2026 生态路线图：Agent Assist 升级为 RAG 驱动、AI Notes 直连 CRM、QA 情感分析提前发现高风险通话。[Balto LinkedIn](https://www.linkedin.com/posts/baltosoftware_in-2026-the-best-contact-center-ai-is-an-activity-7422684464167772160-AMsJ)

### 3.3 Momentum.io《2026 Voice of the Market》报告（2026-01-27 发布）

基于 2000+ 真实 B2B 销售对话的分析：**88% 的团队声称已采用 AI，但只有 24% 把 AI 真正嵌入到营收核心工作流**，多数使用仍是"临时性、脱节的"（如临时贴一段 AI 总结，而非系统性改变工作流程）。[Businesswire 公告](https://www.businesswire.com/news/home/20260127999573/en/Momentum.io-Newest-2026-Voice-of-the-Market-Report-Finds-Most-AI-Adoption-Stops-Short-of-Revenue-Execution)

### 3.4 中国市场信号（数据相对稀疏，检索受限）

- 中国市场当前"实时 AI"话术类产品主要集中在**电销/客服合规与转化场景**，而非高价值 B2B 会议或私董会/教练场景。例如中关村科金（得助智能）2026-06-02 发布的"智能实时销售话术助手"，主打线索自动归档、全链路合规质检、实时意向抓取。[中关村科金](https://www.zkj.com/industry_news/9313.html)
- 腾讯会议基于混元大模型推出"AI 小助手 Pro"，钉钉推出 A1 硬件（录音笔+会议机+翻译机+AI 助理一体），均定位会议记录/组织协作，非主动教练。（百度检索结果，来源为聚合资讯站，未核实为一手信息，标注为推测性弱证据）
- 追一科技等厂商的"智能陪练机器人"是**培训/角色扮演场景**（学-练-考-评闭环），不是真实客户会话中的实时辅助。[追一科技](https://zhuiyi.ai/product/learn)
- **未检索到**中文语境下对标 Hedy AI/Olva/私董会教练定位的成熟商业产品；本项目在中文市场目前处于相对空白的定位窗口（推测，基于检索覆盖有限，建议后续用更多中文垂直信源如 36氪/晚点 二次验证）。

---

## 四、反方证据：实时 AI 建议在真实场景中的坑（🔴 战略级，5 个独立信源）

| # | 证据 | 来源类型 | 具体发现 | 对本项目的警示 |
|---|---|---|---|---|
| 1 | Balto 官方博客自曝弱点 | 厂商一手承认 | "提示延迟 3 秒或丢失会侵蚀坐席信任，采用率会在一个月内崩溃";"通用（未按最佳坐席调优）的提示，坐席会在两周内开始忽略系统" | 触发延迟和提示泛化程度是采纳率的硬约束，不是锦上添花 |
| 2 | Calabrio 数据 / computer-talk.com | 行业调研聚合 | 59% 的呼叫中心从上线后**从未刷新** AI 训练数据；缺乏持续培训会导致"坐席避免使用、信任下降" | 洞察卡片的 prompt/触发器需要持续迭代，一次性调好不代表长期有效 |
| 3 | Sinch《2026 AI Production Paradox》报告（2527 位决策者、10 国、6 行业） | 大样本行业调研 | **74% 的已部署 AI 客服/坐席 agent 被回滚或关停**；治理成熟度更高的组织回滚率反而升到 **81%**（治理能发现问题但不能预防问题）；98% 的企业仍在 2026 加大 AI 投入 | 需注意：此数据覆盖面是"AI 客服/坐席 agent"整体（含自主 agent），不完全等同"实时建议型 agent assist"，但方向性警示成立：**部署容易，长期站住脚难** |
| 4 | Momentum.io《2026 Voice of the Market》 | 一手对话分析（2000+ 真实销售对话） | 88% 声称采用 AI，仅 24% 真正嵌入核心营收工作流；差距在 2026 年"固化成了可测量的采纳鸿沟" | 光有洞察卡片功能不够，要看是否真正改变了会议中的决策行为 |
| 5 | Reddit r/salesdevelopment 一线运营者原始反馈 | 一手实践者证言（非同行评审，样本小） | "一开始不好用：提示太多、太啰嗦，团队被分散注意力；简化之后才开始见效" | 与本项目"卡片要短、尖、可忽略"的设计原则直接吻合，且是独立验证 |
| 6 | Allego × 神经科学家 Carmen Simon（EEG/心率/眼动研究） | 学术合作的一手研究 | AI 反馈让销售代表 48 小时后多记住 50% 内容，但**动机、情绪投入、信任感明显更依赖人类反馈**；观察会让代表说话更多（+45%）但不提升记忆——"看起来投入"不等于"真的学到" | 警示：实时/结构化 AI 建议擅长准确性和记忆，但不能替代人际信任建立；私董会教练场景的"信任"权重可能高于"记忆" |

**综合判断**：现有证据没有证明"实时 AI 建议"这个方向本身是错的；相反，Balto/Cresta/Dialpad 等厂商仍在加码投入（且客户续费）。真正反复出现的失败模式是：**(a) 延迟/丢失导致的不信任、(b) 提示未针对场景裁剪导致的忽略疲劳、(c) 部署后不持续迭代导致的价值衰减、(d) 组织把"用了 AI"等同于"AI 真正改变了工作流"的自我欺骗、(e) 隐身/不可见定位带来的伦理反弹（Cluely）**。这些对应到本项目现有的 speaking budget、卡片来源等级、逐分片交叉纠错等设计已经在正确方向上，但需要持续做"提示密度/命中率"的离线评估，不能假设 prompt 调一次就长期有效。

---

## 五、对本项目的启示（更新自 5 月报告）

1. **TalkPilot 和 nicolelu/live-call-coaching 是需要重点关注的直接对标**：前者验证了"Mac + 快捷键/语音触发 + 屏幕共享不可见"这套交互形态已经有商业化尝试；后者验证了"本地 CLI 驱动、非云端订阅"这条技术路线在开源社区已有人做，值得直接读代码对比架构选择（如是否也用 partial/final 转写稳定策略、如何做"主动教练 tick"节流）。
2. **"教练本人的实时 copilot"细分仍是本项目最大的差异化机会**，Arcade 证明这个产品形态商业上可行，但集中在企业内部销售管理场景；私董会/executive coaching 场景仍待验证，建议后续做 1-2 次用户访谈而非继续纯网络调研。
3. **反方证据应转化为具体的验收指标**：建议给"洞察卡片"补充离线评估维度——(a) 端到端延迟上限（参考 Balto"3 秒即侵蚀信任"的阈值）、(b) 卡片与最近 N 分钟讨论的语义相关度（避免"通用提示两周被忽略"）、(c) 长期使用留存率而非仅首次体验评分。
4. **避免"隐身/不可见"营销叙事**：Cluely、Redix、LiveSuggest、TalkPilot 都在强调"对方看不到""屏幕共享不可见"，这是功能特性但不应是核心卖点；应延续 5 月报告"本机私有、参会者知情、用户控制"的定位。
5. **中文市场目前是相对空窗**，但样本有限，建议下一轮调研针对中文垂直信源（36氪、晚点LatePost、极客公园）做专项二次验证，而不是依赖通用搜索引擎聚合结果。

---

## 不确定项 / 需要进一步验证

- SalesGhost、Redix AI、LiveSuggest、Manja AI、Spiked.ai、7Q.ai 的真实用户规模、融资情况均未找到独立于自身官网/YouTube 频道的第三方验证（YouTube 频道订阅数普遍在几十到几千，需谨慎评估其市场影响力）。
- Sinch 74%/81% 回滚率数据统计口径是"AI 客服/坐席 agent"整体，未拆分出"纯 real-time agent assist"与"自主 AI agent"的差异回滚率，直接套用到本项目场景需谨慎。
- 中国市场"私董会/高管教练实时 AI"细分的空白判断基于有限的百度/Exa 检索（Baidu MCP 工具本轮对多个查询返回 0 结果或不相关会议通稿），建议用知乎、36氪站内搜索或人工检索复核。
- 未能确认 Cluely 2026 年年中的最新 ARR、用户规模等经营指标（仅确认 3 月的 ARR 虚报事件）。
- 微信公众号相关内容本子代理无法直接检索，如需覆盖中文公众号信源（如"崔太阳的AI日记""AI 产品阿禅"等垂直号），建议主线程使用 wechat-article-extractor skill 补充。

---

## 参考来源

### 销售实时辅助（Contact Center / Sales）

- [Cresta: Agent Assist 指南](https://cresta.com/guides/agent-assist-what-it-is-how-it-works-how-to-choose)
- [Cresta Knowledge Agent 发布稿](https://www.prnewswire.com/news-releases/cresta-launches-knowledge-agent-an-agentic-assistant-delivering-proactive-intelligence-to-contact-center-workers-302715345.html)
- [Cresta 客户案例 (Cox)](https://cresta.com/guides/conversational-ai-call-center)
- [Balto: Agent Assist AI 如何提升客服](https://www.balto.ai/blog/how-agent-assist-ai-improves-customer-support)
- [Balto 2026 生态路线图 (LinkedIn)](https://www.linkedin.com/posts/baltosoftware_in-2026-the-best-contact-center-ai-is-an-activity-7422684464167772160-AMsJ)
- [Level AI: Balto 竞品对比 2026](https://thelevel.ai/blog/top-balto-alternatives-and-competitors-in-2026)
- [Dialpad AI Live Coach](https://www.dialpad.com/features/ai-live-coach)
- [Attention Alternatives 2026 (tldv)](https://tldv.io/blog/attention-alternatives)
- [Sybill vs Outreach vs Gong 定位对比](https://www.sybill.ai/blogs/gong-vs-outreach)
- [Demodesk: Zoom Revenue Accelerator 竞品对比](https://demodesk.com/blog/zoom-revenue-accelerator-alternatives)
- [tldv: Zoom Revenue Accelerator 2026 评测](https://tldv.io/blog/zoom-iq-for-sales)
- [Vantage Point: Salesforce Agentforce 2026 指南](https://vantagepoint.io/blog/sf/the-complete-guide-to-salesforces-agentforce-ecosystem-understanding-the-full-product-portfolio-in-2026)
- [Lorikeet: 2026 AI 客服统计 30 项](https://www.lorikeetcx.ai/articles/ai-customer-service-statistics)
- [Gartner 2026 新闻稿：客服领导者需平衡人机能力](https://www.gartner.com/en/newsroom/press-releases/2025-12-17-customer-service-and-support-leaders-must-prioritize-blending-human-strengths-with-ai-intelligence-in-2026)

### 2026 新创产品（需谨慎核实真实影响力）

- [SalesGhost 官网博客](https://salesghost.app/blog/real-time-ai-sales-coaching-guide-2025)
- [Redix AI](https://redixai.com/real-time-sales-coach)
- [LiveSuggest](https://livesuggest.ai/sales-meetings/)
- [Manja AI](https://manja.ai/live_coaching.html)
- [Spiked.ai 访谈 (Selling Power TV)](https://www.youtube.com/watch?v=_sGoKbIOLAc)
- [TalkPilot](https://www.talkpilot.co/)
- [nicolelu/live-call-coaching (GitHub, 开源)](https://github.com/nicolelu/live-call-coaching)

### 教练场景

- [Arcade AI Coach Co-Pilot](https://arcade.co/platform/ai-coaching)
- [CoachHub AIMY](https://www.coachhub.com/aimy)
- [Ovida](https://www.ovida.org)
- [Ovida × Center for Executive Coaching (CoachPilot)](https://centerforexecutivecoaching.com/why-cec/member-support/coachpilot)

### Cluely 与反方证据

- [Inc.com: Cluely CEO ARR 虚报事件](https://www.inc.com/leila-sheridan/an-a16z-backed-startup-that-helps-people-cheat-on-job-interviews-just-got-caught-in-a-7-million-lie-the-ceo-was-sweating/91313070)
- [Cluely - Wikipedia](https://en.wikipedia.org/wiki/Cluely)
- [Postbeam: Cluely 增长复盘](https://www.postbeam.ai/blog/how-cluely-grows)
- [tldv: Cluely 深度评测](https://tldv.io/blog/cluely-review)
- [computer-talk.com: 为什么呼叫中心 AI 会失败](https://www.computer-talk.com/blogs/why-contact-center-ai-could-fail---and-what-to-do-about-it)
- [fin.ai: Build vs Buy，引用 Sinch/RAND/MIT 失败率数据](https://fin.ai/learn/build-vs-buy-ai-customer-service-agent)
- [AIntelligenceHub: 74% 企业回滚 AI Agent（Sinch 报告解读）](https://aintelligencehub.com/articles/ai-agent-rollbacks-2026)
- [Digital Journal: 四分之三大企业回滚 AI Agent](https://www.digitaljournal.com/article/three-in-four-large-enterprises-have-rolled-back-ai-agents)
- [Momentum.io 2026 Voice of the Market 发布稿](https://www.businesswire.com/news/home/20260127999573/en/Momentum.io-Newest-2026-Voice-of-the-Market-Report-Finds-Most-AI-Adoption-Stops-Short-of-Revenue-Execution)
- [Reddit r/salesdevelopment: 实时 AI 异议处理实践反馈](https://www.reddit.com/r/salesdevelopment/comments/1ok20zp/we_tried_using_ai_to_help_reps_handle_objections)
- [Allego: 神经科学研究新闻稿](https://www.allego.com/news/allego-neuroscience-ai-coaching-study/)
- [Allego: AI vs Human 教练神经科学博客](https://www.allego.com/blog/ai-vs-human-sales-coaching/)
- [Allego: 为什么最好的 AI 销售教练不会取代人类](https://www.allego.com/blog/ai-sales-coach-neuroscience-study/)

### 中国市场

- [中关村科金: 智能实时销售话术助手方案](https://www.zkj.com/industry_news/9313.html)
- [追一科技: 智能培训机器人](https://zhuiyi.ai/product/learn)

### 本项目既有调研

- [2026-05-23 Proactive Meeting Agent 与私董会实时 AI 教练调研](./2026-05-23-proactive-meeting-agent-private-board-coach.md)
