STATUS: APPROVED（2026-07-18 工作台评审 session meetingai-v2-review round 2：用户指示"直接把需求都做完，不用分那么多 M"，九条设计决策 8 认可 1 存疑已调整）

# realtime-copilot-v2 合并实施包（原 M0+M1+M2）

设计依据：`docs/design/2026-07-18-realtime-copilot-v2-rethink.md`（status: reviewed）

## 目标

把 AI 介入从"字数阈值触发 + 非流式单管线（端到端 1-3min）"升级为"语义事件 + 全局热键触发、快/深双车道（快车道流式首字 ≤3s）"，手动提问升为一等公民，场景剧本轻量内置。

## 评审约束（必须遵守）

- 不引入本地模型/本地组件；不做模型选型项目，快车道直接用云端快模型（config 可换）
- 不做话轮边界（VAD/endpointing）触发；语义扫描搭在转写流增量上
- 离线评估集不作上线门槛（smoke 级模拟转写做基础回归即可）
- 悬浮条延后不做；剧本内容轻量预设（默认=会议，销售/教练占位可用），深化待用户指定
- 遵守项目守则：新逻辑 RED→GREEN smoke；P2 GUI 测试不在用户开会时跑；严禁日志泄密钥

## 步骤清单

- [ ] S0 读现状代码：AIEngine / MeetingContextBuilder / MeetingViewModel（触发部分）/ Models / InsightFeedView / Config / SettingsView（注意并行会话新增的 ASRResultsWatchdog / TranscriptDisplayTrimmer）
- [ ] S1 Prompt 层：分析 system prompt 四改进（ASR 噪声当前提/宁可一条高杠杆/没有就明说/injection 防御声明）+ 稳定前缀重构（固定说明在前、动态上下文在后，吃 prompt 缓存）→ smoke
- [ ] S2 AIEngine 流式：HTTP 分析改 SSE 流式（deep lane），暴露增量回调；多层解析兜底（JSON→正则→已有数据拼装，不二次调用）→ smoke
- [ ] S3 快车道：`ai.fastModel` 配置（默认云端快模型 @ OpenRouter）+ FastLane 请求路径（短 prompt + 近窗上下文 + 流式）→ smoke
- [ ] S4 卡片与交互：Models 卡片种类扩展（时机型 tip）+ InsightFeedView 一行式（首行价值 + 展开）+ 3 个一键 chip（就刚才这段/我漏了什么/下一步建议）+ "AI 卡住了"可见反馈（发起/完成时间戳 + 超时提示）→ build + smoke
- [ ] S5 全局热键：Carbon RegisterEventHotKey（无需辅助功能权限）唤起 App 并聚焦输入框；"就刚才这段"快捷上下文（最近 N 秒转写）→ build 手测
- [ ] S6 ConversationEventDetector：规则+词典语义扫描（异议/提问/承诺/假设/话题切换/冷场/收尾），转写增量驱动，冷却与密度预算硬约束，事件写 events.log → RED→GREEN smoke
- [ ] S7 场景剧本 Playbook：类型+内置三预设（会议默认/销售/教练）+ SettingsView 选择 + 注入事件词典与话术风格 → smoke
- [ ] S8 触发迁移：深车道触发改为事件/阶段边界为主，保留超时兜底；快车道接事件流；模式（观察者/顾问/研究员）语义映射到密度预算 → smoke 调整
- [ ] S9 回归与文档：swift build + tests/run-p0-p1.sh 全绿；P2 待用户空闲窗口补跑；dev-log/CLAUDE.md/README 同步；openspec change `realtime-copilot-v2` 补录

## 影响文件

Sources/AIEngine.swift、MeetingContextBuilder.swift、MeetingViewModel.swift、Models.swift、InsightFeedView.swift、Config.swift、SettingsView.swift、ContentView.swift（热键/聚焦）；新增 Sources/ConversationEventDetector.swift、Sources/Playbook.swift、Sources/GlobalHotkey.swift；tests/ 新增对应 smoke + run-p0-p1.sh 注册

## 测试计划

每步 RED→GREEN swiftc smoke；S4/S5 涉 UI 的用 build + 既有 fixture 主路径（不 pkill 用户会议中的 App）；最终 headless 全量回归

## 风险

- MeetingViewModel 为并行会话热点文件（今日已被改 3 次）——每次编辑前重读最新版
- 流式改造动 AIEngine 核心路径——保留非流式代码路径作为 fallback 开关（config）
- 语义事件误报——密度预算硬上限 + 冷却，剧本词典保守起步
