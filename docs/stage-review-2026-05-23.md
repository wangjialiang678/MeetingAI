---
title: MeetingAI 阶段性回顾与真实测试准备
date: 2026-05-23
status: active
audience: both
tags: [stage-review, testing, logging]
---

# MeetingAI 阶段性回顾与真实测试准备

## 结论先行

当前代码的自动化基线可通过：`P0/P1` 和 fixture GUI 主流程都已在 2026-05-23 跑通。它证明 App 可构建、可启动、基础 UI 自动化可用、fixture 转写到 AI 卡片再到会话产物这条路径可走通。

但这还不等于可以无风险进入真实会议。真实场景最大的风险集中在三处：

1. **日志完整性存在分支漂移**：历史真实会话里出现过 `.events.log` 和 `.transcript.md`，但当前源码已搜不到对应生成逻辑。
2. **ASR 长会稳定性仍需优先验证**：2026-04-02 的长会事件日志记录了大量 ASR 错误与重连。
3. **入口文档落后于代码**：README 和 `docs/specs/*` 仍有 18080/audio-asr-go/MiniMax 的旧描述，当前代码实际是 18089/asr-bridge/Qwen HTTP + Codex CLI Hybrid。

真实测试前，建议先补齐“每场会议自己的事件日志”，再做一次 20-30 分钟带真实麦克风和联网模型的小型彩排。

2026-05-23 续更：每场会议的 `.events.log` 和 `.transcript.md` 已恢复到当前代码，并纳入 fixture GUI E2E 校验。ASR 重连也已增加去重、指数退避和放弃提示，并纳入 P1 smoke。手动分析限流已改为用户可见提示，并纳入 fixture GUI E2E。真实麦克风 + 联网模型测试入口已拆成两层：短链路 smoke 运行 `scripts/run-real-meeting-smoke.sh 90`，20-30 分钟人工彩排运行 `scripts/run-real-meeting-rehearsal.sh` 采集日志。

2026-05-23 再续更：短链路真实 smoke 已证明当前实时 ASR 会在录音中间产出 partial，不是只在停止录音时产出结果；但 `.txt` 仍只保存 final，因此 partial-only 场景必须依赖 `.transcript.md` 或后续统一 `TranscriptStore`。说话人分离不适合塞入实时 Qwen-ASR 链路，下一阶段建议采用“实时 ASR + 分片录音 Fun-ASR 非实时说话人分离”的双轨架构。详见 `docs/research/2026-05-23-diarization-segmented-transcription.md`。

2026-05-23 录音补充：真实 smoke 暴露本机 MP3 编码创建失败，当前代码已增加单声道 WAV fallback；`docs/runtime-logs/real-smoke-2026-05-23-17-17-30` 验证了真实 ASR partial、HTTP AI `analysis_completed`、非空 `.wav` 录音、`.events.log`、`.transcript.md` 和 `.ai.md`。

2026-05-23 经验沉淀：中间修复、误判、根因和后续守则已整理到 `docs/engineering-lessons-2026-05-23.md`。后续做分片说话人分离前，应先读这份文档里的 `TranscriptStore`、单声道 WAV、真实测试 PASS/FAIL/BLOCKED 和 event log 判据。

2026-05-23 说话人分离实施续更：已按“最快个人原型”决策接入私有 OSS + 官方 OSS Swift SDK + Fun-ASR HTTP。当前 App 会在 chunk 封存后后台上传、提交 Fun-ASR、轮询结果、下载 `transcription_url`、合并 `speaker_id` 句子，并回填 `.diarized.jsonl`、`.transcript.md` 和 UI。真实云端验证需要配置 `MEETINGAI_DIARIZATION_UPLOAD_BUCKET` 与 OSS 凭证；缺配置时 `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1 scripts/run-real-meeting-smoke.sh` 会返回 BLOCKED，而不是伪装成通过。

2026-05-23 review 修复续更：已补上说话人回填不被后续 Markdown 快照覆盖、旧会话 Fun-ASR 回调不污染新会议、`UNKNOWN` 任务状态快速失败、OSS V4 预签名参数脱敏、真实 Fun-ASR smoke 全 chunk 完成判定等回归测试。

2026-05-23 验证续更：`bash tests/run-all.sh` 已通过，包含 P0/P1 与集中 GUI fixture 主路径。`MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1 scripts/run-real-meeting-smoke.sh 1 1` 按预期返回 BLOCKED，原因是当前环境缺 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET`，记录在 `docs/runtime-logs/real-smoke-2026-05-23-19-16-08`。

2026-07-18 续更：真实使用中发生并处置 ASR 端口冲突事故（与 SpeakLow 抢 18089，健康检查假绿，详见 `docs/incident-asr-port-conflict-2026-07-18.md`），MeetingAI 本机端口经 config.json 固定为 18090。同日完成设计优化轮：系统消息拆 `.system` 卡片类型（本文"历史问题回顾"第 5 条闭环）、洞察重复度控制（bigram Jaccard ≥0.85 丢弃）、端口冲突三重代码加固（lsof 预检 + bridge 回环绑定 + /health 身份校验）、Codex 会话两条遗留风险修复（merge 去重按 speaker、drain gate 超时），并同步 README/CLAUDE.md/prd/architecture 文档入口（本文 P1"文档入口同步"闭环）。详见 `docs/dev-log.md` 2026-07-18 条目。

## 本轮查看的材料

- 项目文档：`README.md`、`docs/dev-log.md`、`docs/test-plan.md`、`docs/log-observations-2026-03-06.md`、`docs/research/INDEX.md`、`docs/research/*`
- OpenSpec：`openspec/specs/*`、`openspec/changes/clarify-active-meeting-copilot/*`
- 代码：`Sources/*`、`asr-bridge/*`、`tests/*`
- 项目内 Claude 记忆：`.claude/memory-bank/*`、`.claude/workflow/*`
- Claude Code 对话残留：`~/.claude/projects/-Users-michael-projects----------AI---/*/subagents/*.jsonl`
- 运行日志：`docs/runtime-logs/*`、`~/Library/Logs/MeetingAI-bridge.log`
- 会话产物：`~/Library/Application Support/MeetingAI/sessions/*`
- API key 状态：只检查变量名和是否存在，不读取或写入密钥值

说明：Claude Code 的完整主 transcript 在当前映射目录下没有找到根 `.jsonl` 文件；可用的是 subagent compact 摘要和项目内 memory-bank。因此本文把 Claude Code 记录作为“可用摘要”，不当作完整原始记录。

## 当前代码事实

### ASR

- 当前默认端口：`18089`
- 当前桥接服务：项目内 `asr-bridge/`
- ASR 模型：`qwen3-asr-flash-realtime`
- Swift 侧连接：`ws://127.0.0.1:{port}/v1/stream`
- Go bridge 健康检查：`GET /health`
- Go bridge 日志文件：`~/Library/Logs/MeetingAI-bridge.log`

### AI 后端

- 当前默认 HTTP 模型：`qwen/qwen3.5-122b-a10b`
- 当前默认 HTTP Base URL：`https://integrate.api.nvidia.com/v1/chat/completions`
- 当前分析后端模式：默认 `Hybrid`
- Hybrid 策略：洞察优先走 `Codex CLI`，总结和追问走 HTTP；Codex CLI 失败时回退 HTTP。

### 会议产物

当前源码确认会保存：

- `.txt`：只在收到 final transcript 时追加
- `.mp3`：录音文件
- `.ai.md`：AI 卡片记录，包含后端执行状态
- `.events.log`：JSON Lines 结构化事件日志，记录会议生命周期、配置摘要、ASR/分析关键状态和错误，不记录 API key 值
- `.transcript.md`：会后可读转写快照，标记每条内容是 `[最终]` 还是 `[临时]`

审计时发现的 `.events.log` / `.transcript.md` 生成逻辑缺失已在 2026-05-23 续更中恢复。

## API Key 状态

当前项目代码只读取 `~/.claude/api-vault.env`。

已确认：

- `~/.claude/api-vault.env` 存在
- `~/.Codex/api-vault.env` 不存在
- `DASHSCOPE_API_KEY` 存在，用于 ASR
- `QWEN_API_KEY` 存在，用于当前 HTTP AI 后端
- `MINIMAX_API_KEY` 也存在，但当前默认代码不再使用它
- `~/Library/Application Support/MeetingAI/config.json` 当前不存在，因此会使用代码默认配置

安全要求：

- 不把任何 key 值写入项目文档、日志或测试输出。
- 日志只记录“凭证是否加载”，不要记录 key 前缀。
- 如果后续要切换模型或 Base URL，优先通过 Application Support 下的 `config.json` 覆盖，不在代码里临时改密钥。

## 历史问题回顾

### 1. SPM App 焦点问题

2026-02-27 的复盘记录显示，`swift run` 启动的 SwiftUI App 曾无法获得键盘焦点。根因是 SPM executable 不是标准 `.app bundle`。修复方式是手动设置 activation policy 并激活窗口。

当前项目规则已经保留这一经验：不要只在 SwiftUI 控件层修焦点，先判断 OS 进程层和窗口层。

### 2. ASR 长时间只有 partial，AI 不触发

2026-03-06 的日志观察记录了 7 分钟 4261 行日志、0 条 final。早期触发逻辑依赖 final 数量，因此 AI 不会自动触发。

当前代码已改为按文本长度触发，partial 也参与 `totalTranscriptLength()`，顾问模式 200 字触发，研究员模式 100 字触发。这解决了“没有 final 就不分析”的核心问题。

剩余风险：当前 `.txt` 仍只保存 final。如果真实会议里 final 很少，实时 UI 和 AI 分析可能有内容，但会后 `.txt` 可能不完整。

### 3. MiniMax parseError

早期手动分析出现过 `Failed to parse response`。当前默认 AI HTTP 后端已切到 Qwen/NVIDIA，并且 `AIEngine` 会记录 HTTP 状态码和解析失败的响应片段。结构化分析遇到非 JSON 时会退回原文作为洞察。

剩余风险：HTTP chat completions 外层仍要求 `choices[0].message.content`，如果供应商返回结构变化，仍会失败。

### 4. os.log 隐私遮蔽与噪音

早期观察里提到动态字符串被 `<private>` 遮蔽，且 partial 日志过多。当前代码对音频 chunk 做了降频，初始化日志也不再泄漏 key 前缀。

取舍：这更安全，但真实排错时不能只依赖 `log stream` 看内容，必须保留每场会议自己的 transcript/event 文件。

### 5. 系统消息混在 insight 卡片

2026-03-06 已记录该问题。当前代码仍把系统消息包装成 `.insight`，内容前缀为 `[系统]`。这会让 `.ai.md` 同时包含产品洞察和系统状态。

真实测试时它有好处：能看到 ASR 重连、AI 回退等状态。产品化前建议拆出 `.system` 类型，避免污染洞察流。

### 6. 手动触发的静默跳过

当前代码在最小间隔未满足时只打 debug 日志并 return，用户没有提示。真实会议里，如果用户连续点“立即分析”，可能以为按钮坏了。

建议：手动触发与自动触发分开处理；手动触发被限流时给出明确提示。

### 7. ASR 重连风暴

历史真实事件最值得注意的是 2026-04-02 长会：

- 事件日志共 765 行
- ASR 错误 264 次
- ASR 开始重连 235 次
- ASR 重连成功 235 次
- 重连去重 29 次
- 主要错误：`Socket is not connected`、`connect dashscope: EOF`、DNS `no such host`

这说明真实长会中 ASR 会进入高频断连/重连状态。历史日志里出现了“重连去重”，但当前源码没有搜到这段逻辑。需要确认是否发生了代码回退。

### 8. Claude Code 里的用户反馈

可用 compact 记录里保留了几条关键反馈：

- “log 都充分吗”
- “定期观察 Log，记下所有的问题”
- “如果一直在说呢？如果一直是 partial，可以直接处理流式结果吗”
- “API Key 换成 qwen 3.5，nvidia 那个”

当前代码已响应其中两点：partial 参与分析触发，HTTP 默认 key 改为 `QWEN_API_KEY`。但日志完整性还没有达到真实测试需要。

## 真实日志现状

### 项目内 runtime logs

`docs/runtime-logs/*` 很薄，多数文件只有 log stream 过滤头。只有 2026-03-28 14:59:20 的 unified log 确认过：

- ASR port = 18089
- AI model = `qwen/qwen3.5-122b-a10b`
- dashscope / ai 凭证均已加载

这类日志不足以支撑真实复盘。

### Bridge 日志

`~/Library/Logs/MeetingAI-bridge.log` 当前约 1.8 MB。最近尾部显示大量 2 分钟级 timeout：

- `read dashscope event ... i/o timeout`
- `read client message ... i/o timeout`
- `/v1/stream 200 2m0s`

这表明 bridge 端已经有有用日志，但还缺少和 App 会话 ID 对齐的结构化事件。

### Session 产物

`~/Library/Application Support/MeetingAI/sessions/` 当前有 29 个文件。重要样本：

- 2026-03-06：有真实 `.txt` 和 `.ai.md`
- 2026-03-28：有 `.txt`、`.transcript.md`、`.ai.md`、部分 `.events.log`
- 2026-04-02：有长会 `.txt`、`.transcript.md`、`.ai.md`、`.events.log`

会话产物证明 App 曾经具备较完整的事后复盘能力；当前代码需要恢复并固定这套能力。

## 本轮验证结果

2026-05-23 已执行：

```bash
bash tests/run-p0-p1.sh
```

结果：PASS。覆盖 Go build、Swift build、context builder smoke、App launch smoke、Accessibility precheck、关键代码集成检查。

```bash
bash tests/run-p2-ui.sh
```

结果：PASS。fixture GUI 主流程通过，产物校验为 `txt=1, mp3=1, ai=1`。

短链路已覆盖：

- 真实麦克风输入
- DashScope 实时 ASR partial 输出
- Qwen/NVIDIA HTTP 真实调用
- 每场 `.events.log` / `.transcript.md` / `.ai.md` 产物
- MP3 不可用时的 WAV 录音 fallback

尚未覆盖：

- DashScope 实时 ASR 长连接稳定性
- Codex CLI 在 App 内长时间被频繁调用的稳定性
- 长会中 ASR reconnect/backoff 行为
- partial-only 情况下的会后 transcript 完整性
- 录音分片上传与 Fun-ASR 说话人分离

## 真实测试前建议清单

### 必须先补

1. 恢复或重建每场会议的 `.events.log`
   - 状态：已恢复并纳入 `tests/fixture_meeting_e2e.sh`
   - 记录会议开始/结束
   - 记录配置摘要：端口、模型、backend、fixture、凭证是否存在
   - 记录 ASR server 启动、健康检查、连接、started/final/finished/error
   - 记录 ASR 重连开始、成功、失败、去重、放弃
   - 记录分析触发原因、文本增量、backend 选路、耗时、回退
   - 严禁记录 API key 值

2. 恢复或重建 `.transcript.md`
   - 状态：已恢复并纳入 `tests/fixture_meeting_e2e.sh`
   - 至少能保存 partial/final 的最终可读版本
   - 标明 `[临时]` 或 final 状态
   - 避免出现 UI 有内容但会后文件空白

3. 给 ASR 重连加去重和退避
   - 状态：已实现并纳入 `tests/asr_reconnect_policy_smoke.sh`
   - 同一时间只允许一个 reconnect task
   - 连续失败要递增 backoff
   - 达到上限后给用户明确提示

4. 修正手动分析限流提示
   - 状态：已实现并纳入 `tests/fixture_meeting_e2e.sh`
   - 自动触发可静默跳过
   - 用户点击必须给反馈

5. 新增说话人分离分片链路
   - 状态：已实现本地 chunk、OSS 上传、Fun-ASR 提交/轮询/下载、merge/backfill 和 UI 回填；真实云端端到端验证仍等待 OSS bucket/凭证
   - 实时 Qwen-ASR 继续负责会议中 partial/final
   - 分片录音通过 Fun-ASR 非实时 HTTP 开启 `diarization_enabled`
   - 真实 smoke 必须使用 `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1` 单独打开

### 测试当天建议

启动前准备一个本地日志目录，例如：

```bash
scripts/run-real-meeting-smoke.sh 90
scripts/run-real-meeting-rehearsal.sh
```

会议结束后立刻归档：

- `docs/runtime-logs/{RUN_ID}/*`
- 本场 `~/Library/Application Support/MeetingAI/sessions/{timestamp}*`
- `~/Library/Logs/MeetingAI-bridge.log` 的相关时间片段

复盘时优先回答：

1. ASR 是否稳定出 partial / final？
2. partial-only 时 AI 是否正常发言？
3. 会后 transcript 是否完整？
4. AI 输出是否过频或重复？
5. Codex CLI 是否频繁失败并回退？
6. ASR 是否出现 reconnect storm？
7. 用户能否从 UI 看懂当前失败或回退状态？

## 下一步开发优先级

P0：配置 OSS bucket/凭证后跑一次 `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1` 真实 Fun-ASR smoke，确认云端链路、`.diarized.jsonl`、Markdown 回填和脱敏判据。

P1：做 20-30 分钟真实麦克风 + 联网模型彩排，重点观察 ASR 长连接稳定性、partial/final 比例、AI 输出频率和 Fun-ASR 后台任务耗时。

P1：文档入口同步。README、`docs/specs/prd.md`、`docs/specs/architecture.md` 至少要标注已过时或对齐 OpenSpec 和当前代码。

P2：产品体验优化。系统消息拆类型、手动限流提示、AI 发言预算和重复度控制。
