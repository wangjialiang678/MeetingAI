STATUS: APPROVED（用户原始指令「根据优化后的方案更新一个版本」即为执行授权）

# 2026-07-18 设计优化与版本更新计划

## 背景与调研结论

最新版本确认为主目录 `会议中AI给建议`（工作区含 2026-05-23 全部未提交的 diarization 双轨工作）；同级 6 个副本目录均为旧版。

设计与日志复查发现的可优化点（按来源）：

| # | 问题 | 来源 | 本轮处理 |
|---|---|---|---|
| 1 | 项目 CLAUDE.md / docs/specs/prd.md / architecture.md 严重过时（MiniMax、18080、audio-asr-go、ChatView、final 条数触发） | stage-review P1 + 本轮核对 | ✅ 同步 |
| 2 | 系统消息混入 `.insight` 卡片，靠 `[系统]` 前缀过滤，污染 `.ai.md` 与上下文 | stage-review P2 #5 + Models.swift/MeetingViewModel.swift:577 核实 | ✅ 拆 `.system` 类型 |
| 3 | AI 洞察无重复度控制，只靠 prompt 指令 | stage-review P2 | ✅ 轻量相似度去重 |
| 4 | ASRServerManager 启动前不处理 18089 旧进程残留；bridge log 反复出现 `bind: address already in use`；且 `pkill asr-bridge` 会误杀 SpeakLow 同名进程 | bridge log + 本轮实测（PID 84050 为 SpeakLow 进程） | ✅ 启动前检测/清理同路径旧进程 |
| 5 | `.txt` 仅 final，TranscriptStore 未做 | lessons #3 | ⏭ 下轮（改动面大，`.transcript.md` 已兜底） |
| 6 | OSS 凭证缺失，Fun-ASR 真实链路 BLOCKED | 最新 smoke manifest + api-vault 变量名核对 | ⏭ 需用户配置（阿里云开通 OSS + 写入 api-vault + 设 bucket env） |
| 7 | 20-30 分钟真实彩排未做 | stage-review P1 | ⏭ 需真人参与 |

Codex 对话分析（后台子代理）返回后，如发现未覆盖的代码缺陷，追加到本计划底部并处理。

## 实施步骤

- [x] S1 文档同步：CLAUDE.md 重写对齐；prd.md 标记 historical + 差异说明；architecture.md 对齐；README 端口说明修正
- [x] S2 系统消息拆类型：`.system` kind + FeedView 样式 + ContextBuilder 按 kind 过滤 + `.ai.md` 🔧 前缀；fixture E2E 断言兼容（grep 内容不依赖前缀）
- [x] S3 洞察重复度控制：InsightDeduplicator + 双落卡点接入 + P0-16 smoke
- [x] S4 端口冲突防御（超出原计划，落地事故复盘全部三条加固）：ASRBridgePortGuard lsof 预检 + bridge 显式绑定 127.0.0.1 + /health 身份校验 + P0-17/P1-28~30
- [x] S4b Codex 会话遗留风险：merge 去重按 speakerID；AudioTapDrainGate 超时（stop 2s 上限）
- [x] S5a 回归：swift build + go build + bash tests/run-p0-p1.sh 全 PASS
- [ ] S5b P2 GUI fixture：暂缓——执行时用户正在真实开会（P2 会 pkill App）；后台监视会议结束后补跑
- [x] S6 文档收尾：dev-log 新条目、stage-review 2026-07-18 续更、handoff 更新
- [ ] S7 版本提交：改为单一版本提交（5月23 与本轮改动已在同批文件中纠缠，无法干净拆分；含并行会话的端口事故文档）；等 P2 通过后执行

执行中发现与决策记录：
- 并行会话处置了真实端口冲突事故（SpeakLow 抢 18089），已定端口所有权 MeetingAI=18090（config.json）；本轮沿用该决策，未改代码默认值
- 用户会议进行中（sessions/2026-07-18-15-25-00），P2 与 App 重启均推迟，避免打断录音

## 影响文件

Sources/Models.swift、MeetingViewModel.swift、InsightFeedView.swift、MeetingContextBuilder.swift、ASRServerManager.swift；新增 Sources/InsightDeduplicator.swift；tests/（新增 2 个 smoke + run-p0-p1 接入 + fixture E2E 兼容）；CLAUDE.md、README.md、docs/specs/*、docs/dev-log.md、docs/stage-review-2026-05-23.md

## 测试计划

- 每个代码步骤先跑对应单项 smoke（RED/GREEN 按项目惯例）
- 全量 `bash tests/run-all.sh` 通过后才提交
- 不跑真实联网 smoke（本轮不动实时 ASR/AI 协议路径；bridge 启动防御用单元级验证）

## 风险

- fixture E2E 对 `.ai.md` 中系统提示的断言可能依赖 `[系统]` 前缀 → 改动前先读脚本断言
- InsightFeedView 对 kind 的 switch 需穷举，新增 case 会编译期暴露所有遗漏点（可控）
- lsof 探测在 App sandbox 外的 dev 环境可用；若将来打包上架需重新评估
