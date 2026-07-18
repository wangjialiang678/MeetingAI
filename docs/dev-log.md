# 开发过程日志

## 2026-07-18 - 晚间收尾：静音超时、模式可观测、E2E 断言、首推 GitHub

### 变更
- `asr-bridge` DashScope 读超时 2min→10min（`dashscopeIdleTimeout`）：17:47 场观测到连续静音期每 2 分钟一轮断连刷屏（bridge 读超时所致，非网络/代理）；客户端环路维持 120s
- 会议事件记录 `aiMode`，模式切换写 `ai_mode_changed`（17:29 场整场 0 分析无法归因的可观测性缺口）
- fixture E2E 转写就绪断言兼容新计数文案"N 段"（TranscriptView 改版后"3 条"断言过时导致 P2 误报）
- 项目首次推送 GitHub（私有仓库）

### 观察记录
- 17:47 场（约 40 分钟）：说话人分离全程自动回填 232 句（含静音分片 0 句正常完成——静音修复首次真实生效）；按需发言生效（内容单薄时 2 次沉默，实质内容才发声）；NO_PROXY 直连后断连均为单发、2 秒内恢复
- 该场用户未点"结束会议"直接关窗：`.transcript.md`/`.diarized.jsonl`/`.events.log` 完整，`.txt` 完整重写与录音收尾缺失。后续待办：窗口关闭/应用退出时自动触发 stopMeeting 收尾
- 18:00 观测到一次 DashScope 服务端错误 `1011 model repeat output happened`（上游模型问题，重连自愈，备案）

### 验证
- `bash tests/run-p0-p1.sh` + `bash tests/run-p2-ui.sh` → 全 PASS（断言修复后重跑）

## 2026-07-18 - 会议中滚动替代 + 逐分片 LLM 纠错（用户需求）

### 需求
- 用户："说话人分离回填后，实时转写就可以被替代了……在会议中，就会不断地替代、纠正；对比两份转写用大模型纠正明显识别错误（置信度高）"
- 两份转写来自不同引擎（实时 qwen3-asr / 非实时 Fun-ASR），错误互不相关，交叉验证有效

### 变更
- 新增 `Sources/TranscriptRefiner.swift`：纠错提示词（保守：仅高置信度同音字/专名/数字，禁止润色/改写/增删）+ 修正解析（只接受文本替换，数量/顺序/时间戳/说话人不变；任何异常退回原句）
- `DiarizationPipeline` 增加可选 `sentenceRefiner` 钩子：分片识别完成后、合并前调用；有修正时写 `diarization_chunk_refined` 事件
- `MeetingViewModel.refineDiarizedSentences`：取该分片时间窗内的实时转写做参考，调 GLM（`AIEngine.rawCompletion`）纠错；失败原样返回不阻塞；fixture 模式跳过
- `TranscriptView` 改为滚动替换布局：说话人段落（已处理）为主体，实时转写只显示未覆盖尾巴（活跃 partial 截尾 600 字防重复）；计数改为"N 句已处理 · M 段实时"（修掉此前"0 条"误导）
- `MeetingViewModel` 新增 `meetingStartDate` / `speakerCoverageCutoffDate` 支撑时间对齐

### 验证
- `transcript_refiner_smoke`（7 用例：提示词、修正应用、围栏响应、非法响应回退、越界忽略、时间戳/说话人不变、上下文截断）→ PASS
- `swift build` + `bash tests/run-p0-p1.sh`（新增 P0-19、P1-35/36）→ PASS
- P2 与真实效果验证待当前会议（17:47 场）结束后进行
- 原始数据不受影响：`.diarized.jsonl`/`.transcript.md` 记录的是纠错后的句子（含事件审计），实时转写原文仍完整落盘 `.txt`

## 2026-07-18 - DashScope NO_PROXY 直连（代理断连风暴处置）

### 背景
- 17:29 场真实会议出现持续断连风暴：每 30-90 秒一次 `Connection reset by peer` / `connect dashscope: EOF`，重连状态机全部接住（attempt 1-3 内恢复），会议未中断但转写有小缺口
- 特征与事故文档备案的本机 Clash 代理长连接闲置超时/重置一致，达到其"频繁复发再处理"的阈值；按其候选方案实施
- 同场好消息：说话人分离自动链路首次在真实会议中全自动生效（chunk 2+ 实时上传→Fun-ASR→回填，会议中 .diarized.jsonl 持续增长）；chunk 0/1 因同期代理抖动 OSS 上传失败（AlibabaCloudOSS.ClientError），本地 WAV 保留待离线补跑

### 变更
- `ASRBridgePortGuard.noProxyValue(merging:)`：合并已有 NO_PROXY 条目并追加 `dashscope.aliyuncs.com`，不重复
- `ASRServerManager` 启动 bridge 时注入 `NO_PROXY`/`no_proxy`（Go dialer 读取 env），DashScope 直连绕开本机代理

### 验证
- RED→GREEN：`asr_stale_bridge_policy_smoke` 新增 4 个合并用例
- `swift build` + `bash tests/run-p0-p1.sh` → PASS
- P2 GUI 回归推迟：执行时用户正在开会（P2 会 pkill App）；会议结束后补跑
- 真实效果验证：下次 App 重启后的会议观察 asr_error 频率是否归零

## 2026-07-18 - 按需发言 + TranscriptStore + 事件日志降噪（彩排复盘三项落地）

### 变更（对应彩排复盘三决策：发言按需、2/3 直接改）
- **按需发言**：顾问模式 prompt 改为默认沉默（仅关键盲点/方向性风险/行动项/真正新信息才发言，不复述共识）；最小输出间隔 120s→180s；连续沉默强制发声兜底 3 次→5 次
- **TranscriptStore**：新增 `Sources/TranscriptStore.swift`，停止会议时用全部 entries（partial+final）重写 `.txt` 为完整版（导入的历史条目除外）；会议中 final 追加行为保留作崩溃兜底。解决 6917 partial 对 2 final 下 `.txt` 名存实亡的问题
- **skip 事件降噪**：自动触发的 `analysis_skipped` 在两次分析之间只记录一次（手动触发始终记录且有 UI 提示）；"暂无新转写内容"提示改为仅手动触发时显示

### 验证
- RED：`transcript_store_smoke` → FAIL（文件不存在）；GREEN → PASS（partial-only 完整性、空行跳过、历史条目排除、时间格式）
- `swift build` + `bash tests/run-p0-p1.sh`（新增 P0-18、P1-33/34）+ `bash tests/run-p2-ui.sh` → 全部 PASS
- 降噪与按需发言的真实效果待下一场会议由后台监控验证（skip 事件量、发言频率）

## 2026-07-18 - 31 分钟真实彩排复盘 + 说话人分离离线补跑

### 观察（session 2026-07-18-16-30-12，31 分钟真实多人会议）
- ASR 全程 0 错误 0 重连（对照 2026-04-02 的 264 错误/235 重连），一次连接撑满全场
- AI 分析 15 次全部完成、0 失败 0 回退；GLM 5.2 多数 10-24s、一次 74s 尖刺（OpenRouter 波动）；2 张小结卡证明话题切换检测生效；洞察去重 0 触发
- **partial-only 极端化：6917 partial vs 2 final**，`.txt` 基本为空；TranscriptStore 优先级应提升
- 事件日志噪声：4623 条 `min_interval` skip 事件（每条 partial 都写）占 events.log 大半，待降噪
- **说话人分离管线未启动**：config.json 只配了 `uploadBucket` 漏了 `uploadStorage: "oss"`，管线静默禁用（smoke 走env覆盖所以没暴露）。已修 config 并在 CLAUDE.md 记录此坑

### 补救
- 31 个本地分片离线补跑：aliyun CLI 上传 OSS → Fun-ASR 单任务批量提交（31 file_urls）→ 回填 `.diarized.jsonl`（327 句）与 `.transcript.md`
- 识别出 4 个说话人（speaker-0: 246 句 / speaker-1: 63 / speaker-2: 15 / speaker-3: 3），15/31 分片内含多说话人；跨 chunk speaker 编号稳定性仍属已知限制，未验证同名即同人

### 待办（复盘产生，未动手）
- min_interval skip 事件降噪（只在状态变化或 manual 时写）
- TranscriptStore：partial-only 场景 `.txt` 完整性
- AI 发言预算：顾问模式贴 120s 下限每 2 分钟一卡，密度待用户评价
- App 内增加"旧会话补跑说话人分离"入口（本次为脚本手工补跑）

## 2026-07-18 - Fun-ASR 真实链路首次 PASS：静音分片修复

### 变更
- 首次真实 Fun-ASR smoke 失败，手动重放拿到云端根因：`ASR_RESPONSE_HAVE_NO_WORDS`——2 秒短分片切在静音段，云端任务标 FAILED，provider 误当链路失败
- `DashScopeFunASRProvider`：任务失败且全部错误码为 `ASR_RESPONSE_HAVE_NO_WORDS` 时返回"成功但 0 句"（真实会议静音常见，不算失败）；其他失败错误信息带上云端 code（此前只有 "ended with FAILED"，unified log 又被 `<private>` 脱敏，几乎不可排查）
- `DashScopeFunASRTaskResponse` 新增顶层 code/message 捕获与 `failureCodes` 汇总

### 验证
- RED：`fun_asr_provider_smoke` 新增静音空结果、错误码透传两用例 → FAIL
- GREEN：provider smoke → PASS；`swift build` → PASS
- **真实 Fun-ASR smoke → PASS**（`docs/runtime-logs/real-smoke-2026-07-18-16-27-27`）：4 chunk 上传 OSS、云端任务完成、`.diarized.jsonl` 产出 speaker 句子、`.transcript.md` 回填区块正常。stage-review 的 P0（真实云端说话人分离验证）正式闭环
- 链路配置：bucket `audio-asr-temp`（`meetingai/chunks` 前缀）、凭证从 server-vault 复制到 api-vault、config.json 增加 `diarization.uploadBucket`

### 备注
- 单人合成语音只有 speaker-0，多说话人区分效果需真实多人会议观察
- 云端 chunk 属临时副本（本地为主副本）；audio-asr-temp 为共享临时桶，后续可考虑生命周期清理

## 2026-07-18 - GLM JSON 围栏解析修复 + OSS 说话人分离链路配置

### 变更
- 修复真实会议暴露的 bug：GLM 5.2 把结构化 JSON 包在 ```` ```json ```` 代码围栏里，解析失败后原始 JSON 被当作洞察全文显示在卡片上。`AIEngine` 新增 `extractStructuredJSONText`：剥代码围栏、容忍 JSON 前后夹带说明文字、纯文本原样返回
- 结构化输出的 `kind` 若为 `system` 强制降为 `insight`（`.system` 保留给 App 自身状态消息，模型不允许自称系统）
- OSS 说话人分离链路配置落地（用户确认 bucket 已存在）：server-vault 中的 `OSS_ACCESS_KEY_ID/SECRET` 复制到 api-vault.env（App 只读后者）；config.json 增加 `diarization.uploadBucket = audio-asr-temp`（endpoint 用默认北京）；凭证已用 aliyun CLI 实测可列出 bucket
- 说明：audio-asr-temp 是共享临时音频桶，MeetingAI 用 `meetingai/chunks` 前缀隔离；本地 chunk 仍是主副本，云端副本仅供 Fun-ASR 处理

### 验证
- RED：`ai_response_parsing_smoke` 新增 6 个围栏/夹带文本用例 → FAIL（函数不存在）
- GREEN：`swiftc ... ai_response_parsing_smoke` → PASS；`swift build` → PASS
- `bash tests/run-p0-p1.sh` → PASS
- `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1` 真实 smoke：待用户当前会议（16:08 场）结束后执行（脚本会 pkill App 并播放测试音频）

### 备注
- 用户实测 GLM 5.2 HTTP 洞察耗时 9.4s（对比 Codex CLI 54.8s），后端切换收益明确
- 当前运行中的 App 实例仍是围栏修复前的二进制，会议结束重启后生效

## 2026-07-18 - 设计优化轮：系统消息拆类型、洞察去重、端口冲突加固

### 背景
- 本轮先做了三件调研：确认主目录为唯一最新版本（同级 6 个副本目录均停在 2026-03-28 ~ 2026-05-23 16:51）；回读 2026-05-23 Codex 会话记录提取遗留风险；复查 stage-review 的 P1/P2 待办
- 与下一条目的端口冲突事故处置为同日并行会话；本轮把该复盘"尚未落地"的三条代码加固全部落地并回归（下条目中"guard 未提交未回归"的提醒已由本条验证解除）

### 变更
- `InsightCard.Kind` 新增 `.system`：系统消息不再以 `[系统]` 前缀混入 `.insight`；`MeetingContextBuilder` 改按 kind 过滤，`.ai.md` 中系统卡片用 `🔧 [系统]` 前缀标注，`InsightFeedView` 灰色弱化样式
- 新增 `Sources/InsightDeduplicator.swift`：新洞察与最近 3 张洞察卡做字符 bigram Jaccard 相似度，≥0.85 丢弃并写 `analysis_discarded_duplicate` 事件；手动触发被去重时给可见系统提示，自动触发静默；强制发声路径同样过重复检测
- Codex 会话遗留风险修复一：`DiarizationMerger` 去重要求 `speakerID` 相同——重叠窗内不同说话人的相同短句不再被误合并（宁可重复不误删）
- Codex 会话遗留风险修复二：`AudioTapDrainGate.waitForIdle` 支持超时（stop 用 2 秒上限），tap 回调卡死不再永久阻塞停止会议
- 端口冲突三重加固（对应事故复盘"尚未落地"清单）：
  1. 新增 `Sources/ASRBridgePortGuard.swift`，启动 bridge 前 lsof 预检端口——自家残留进程自动清理，外来进程明确报错（绝不误杀 SpeakLow）
  2. `asr-bridge/main.go` 改为显式绑定 `127.0.0.1`（端口被占立刻 bind 失败，不再静默共存），并重建 `bin/asr-bridge`
  3. `/health` 增加 `service: meetingai-asr-bridge` 身份字段；`ASRServerManager` 健康检查校验身份，同源衍生服务应答假绿时按端口占用快速失败
- 文档同步：根 `CLAUDE.md` 重写对齐当前代码（技术栈/触发阈值/产物/测试入口）；`docs/specs/prd.md` 标记 historical 并附差异说明；`docs/specs/architecture.md` 组件/数据流/触发机制对齐；新增 `docs/handoff-2026-07-18.md` 交接速览
- `tests/run-p0-p1.sh` 新增 P0-16（洞察去重 smoke）、P0-17（端口守卫 smoke）、P1-26~P1-30（系统卡类型/去重接线/端口守卫/回环绑定/健康身份）

### 验证
- RED/GREEN：`diarization_merge_smoke`（不同 speaker 不去重回归）、`audio_recorder_drain_gate_smoke`（超时用例）、`insight_deduplicator_smoke`、`asr_stale_bridge_policy_smoke` 均先 FAIL 后 PASS
- `swift build` → PASS；`/opt/homebrew/bin/go build -o bin/asr-bridge .` → PASS
- `bash tests/run-p0-p1.sh` → PASS（含全部新增检查）
- `bash tests/run-p2-ui.sh` → 暂缓：执行时用户正在用 App 开真实会议（sessions/2026-07-18-15-25-00 持续写入），P2 开头的 `pkill -x MeetingAI` 会杀掉进行中的会议；已挂后台监视，会议结束后补跑

### 追加：AI 后端切换 GLM 5.2（用户决策）
- 用户观察真实会议中 Hybrid → Codex CLI 洞察耗时 54.8s，指示"先不考虑 Codex CLI，用 API Key + GLM 5.2"
- `Config.swift` 新增 `ai.apiKeyEnv` 配置：HTTP 后端 key 的环境变量名可配（默认 `QWEN_API_KEY`），换供应商只改 config 不改代码
- 默认分析后端 `.hybrid` → `.http`（UserDefaults 已存选择的用户不受影响；Codex CLI/Hybrid 仍可在设置切换）
- 本机 `config.json` 更新为 `z-ai/glm-5.2` @ `https://openrouter.ai/api/v1/chat/completions`（`OPENROUTER_API_KEY`，api-vault 已有，无需新申请；OpenRouter 实测 200 + content 正常，附 reasoning 字段，解析器已兼容）
- `tests/run-p0-p1.sh` 新增 P1-31（默认后端 http）、P1-32（apiKeyEnv 可配）

### 备注
- 未改端口默认值（Config.swift 仍 18089）：端口所有权决策（MeetingAI=18090 via config.json）由事故处置会话做出并写入硬规则，本轮沿用，不重复决策
- 真实会议截图观察（2026-07-18 15:25 场）：转写面板计数"0 条"但有大量 partial 内容——计数只数 final，有误导性，列入后续 UI 待办；15:41 一波 ASR 重连（1/3→3/3→恢复）与事故文档备案的本机代理 7897 闲置超时特征吻合，重连状态机工作正常
- TranscriptStore 统一重构、AI 发言预算细化、转写计数含 partial 仍在待办（见 stage-review 优先级）

## 2026-07-18 - ASR 端口冲突事故（与 SpeakLow 撞 18089）修复与复盘

### 变更
- **无代码变更**。新建 `~/Library/Application Support/MeetingAI/config.json`，把 ASR 端口从默认 18089 改为 18090，永久避开 SpeakLow 自带 asr-bridge 占用的 18089
- 新增 `docs/incident-asr-port-conflict-2026-07-18.md`：事故复盘、根因机制（具体地址/通配地址共存导致 bind 无报错 + 健康检查被别人应答 + 重连计数被握手成功重置）、复发排查 checklist、P2 代码加固建议
- 同步 `docs/handoff-2026-07-18.md`（端口改 18090、已知坑第 2 条挂复盘链接）与项目 `CLAUDE.md`（端口引用改 18090）
- 备注：同日有并行开发会话在改代码（15:30 加入 `ASRBridgePortGuard.swift` 端口预检 + 更新 CLAUDE.md），本次文档工作与其无冲突；guard 未提交未回归，接手者先跑 `tests/run-p0-p1.sh` 再依赖

### 验证
- 修复后真实会议（session `2026-07-18-15-25-00`）：bridge 监听 18090、`/v1/stream` 连通、`transcript_partial` 持续写入 → PASS
- 备案一次独立的上游断连：DashScope 连接走本机代理 `127.0.0.1:7897` 约 2 分钟闲置超时，重连 1 次恢复，暂不处理

## 2026-05-23 - Fun-ASR diarization review fixes

### 变更
- 修复 `.transcript.md` 后续快照覆盖“说话人分离回填”的问题；实时转写快照现在会保留已有回填区块，有新 speaker segments 时再替换。
- 增加会话代际 gate，避免上一场会议的异步 Fun-ASR 任务晚返回后污染下一场会议 UI。
- Fun-ASR 任务状态 `UNKNOWN` 改为快速失败，不再轮询到超时。
- OSS V4 预签名参数脱敏覆盖 `x-oss-credential` 和 `x-oss-security-token`。
- 真实 Fun-ASR smoke 改为失败优先，且只有所有 finalized chunks 都完成后才判定 completed。
- `.chunks.jsonl` 的 waiting 文案改为中性“Waiting for upload processing”，避免 provider 已配置时日志误导。

### 验证
- `swift build` → PASS
- 单项 RED/GREEN：`transcript_markdown_writer_smoke`、`diarization_session_gate_smoke`、`fun_asr_provider_smoke`、`diarization_chunk_lifecycle_smoke`、`real_meeting_smoke_fun_asr_outcome.sh` → PASS
- `bash tests/run-p0-p1.sh` → PASS
- `bash tests/run-all.sh` → PASS
- `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1 scripts/run-real-meeting-smoke.sh 1 1` → BLOCKED（缺 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET`，日志：`docs/runtime-logs/real-smoke-2026-05-23-19-16-08`）
- `git diff --check` → PASS

## 2026-05-23 - OSS/Fun-ASR 真实说话人分离接入

### 变更
- 用户决策采用最快个人原型路线：私有 OSS bucket + 官方 OSS Swift SDK + Fun-ASR 非实时 HTTP，保留全部本地和云端 chunk
- `Package.swift` 引入 `alibabacloud-oss-swift-sdk-v2`，新增 `Sources/DiarizationOSSUploader.swift`，通过 `putObject` 上传单声道 WAV chunk，并为 Fun-ASR 生成 GET 预签名 URL
- 新增 `Sources/DiarizationOSSSupport.swift`，集中处理 OSS endpoint 归一化、object key 生成、presign TTL 限制和配置 readiness，不把本地路径写入对象 key
- 新增 `Sources/DiarizationFunASRProvider.swift`，实现 Fun-ASR submit request、异步 task polling、`transcription_url` 下载和 `transcripts[].sentences[].speaker_id` 解析
- 新增 `Sources/DiarizationPipeline.swift`，把 sealed chunk 串到 upload -> submit -> poll -> merge -> backfill，成功/失败生命周期写入 `.events.log`
- `MeetingViewModel` 在真实会议流中根据配置启动后台说话人分离 pipeline；chunk 封存后自动排队上传，不阻塞实时 ASR
- `TranscriptView` 新增“说话人分离回填”区域，后台结果到达后在 UI 中显示 speaker/time/text，同时 `.transcript.md` 仍只追加回填区块，不覆盖实时转写原文
- `AppConfig` 新增 OSS/Fun-ASR 配置与 env 覆盖，密钥只从 process env 或 `~/.claude/api-vault.env` 读取，日志只记录 credentialLoaded 布尔值
- `scripts/run-real-meeting-smoke.sh` 增加 `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1` 模式；缺 OSS bucket/凭证时返回 BLOCKED，启用后要求 `.diarized.jsonl`、speaker markdown、Fun-ASR completed 事件和签名 URL 不落日志
- `docs/diarization-storage-decision.md`、`docs/test-plan.md`、`docs/research/2026-05-23-diarization-segmented-transcription.md`、`docs/engineering-lessons-2026-05-23.md` 和 OpenSpec tasks 已同步

### 验证
- RED：`swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationFunASRProvider.swift tests/fun_asr_provider_smoke.swift -o .build/fun_asr_provider_smoke && ./.build/fun_asr_provider_smoke` → FAIL（`Sources/DiarizationFunASRProvider.swift` 不存在）
- RED：`swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationBackfillWriter.swift Sources/DiarizationPipeline.swift tests/diarization_pipeline_smoke.swift -o .build/diarization_pipeline_smoke && ./.build/diarization_pipeline_smoke` → FAIL（`Sources/DiarizationPipeline.swift` 不存在）
- RED：`swiftc Sources/DiarizationModels.swift Sources/DiarizationOSSSupport.swift tests/diarization_oss_support_smoke.swift -o .build/diarization_oss_support_smoke && ./.build/diarization_oss_support_smoke` → FAIL（`Sources/DiarizationOSSSupport.swift` 不存在）
- `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationFunASRProvider.swift tests/fun_asr_provider_smoke.swift -o .build/fun_asr_provider_smoke && ./.build/fun_asr_provider_smoke` → PASS
- `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationBackfillWriter.swift Sources/DiarizationFunASRProvider.swift Sources/DiarizationPipeline.swift tests/diarization_pipeline_smoke.swift -o .build/diarization_pipeline_smoke && ./.build/diarization_pipeline_smoke` → PASS
- `swiftc Sources/DiarizationModels.swift Sources/DiarizationOSSSupport.swift tests/diarization_oss_support_smoke.swift -o .build/diarization_oss_support_smoke && ./.build/diarization_oss_support_smoke` → PASS
- `swift build` → PASS
- `bash tests/run-p0-p1.sh` → PASS

### 备注
- 真实 Fun-ASR 云端任务尚未执行；需要先配置 `MEETINGAI_DIARIZATION_UPLOAD_BUCKET` 和 OSS 凭证。缺失时真实 smoke 会返回 BLOCKED。
- 预签名 URL query 不写 `.events.log` / `.chunks.jsonl`；日志只保留 host/path 和 object key。
- Fun-ASR `speaker_id` 暂按 provider 结果显示为 `speaker-N`，不假设跨 chunk 恒定对应同一真人。

## 2026-05-23 - 本地说话人分片生命周期

### 变更
- 根据测试策略反馈，`tests/run-p0-p1.sh` 不再执行 App launch smoke 或 Accessibility precheck；P0/P1 保持 headless，GUI 自动化集中到 `tests/run-p2-ui.sh` 的单个 fixture 主流程
- 新增 `Sources/DiarizationBackfillWriter.swift`，把已合并的 fake/provider speaker segments 写入 `{session}.diarized.jsonl`，并向 `.transcript.md` 追加“说话人分离回填”区块
- 新增 `Sources/DiarizationProviderBoundary.swift`，定义 uploader protocol、上传结果、转写请求、provider task 和无密钥配置占位
- 新增 `tests/diarization_backfill_smoke.swift`，覆盖 `.diarized.jsonl`、speaker line 格式、保留原始实时转写内容、不写入 home path、fake provider chunk result -> merge -> backfill，以及安全的 `diarization_backfill_saved` 事件
- 新增 `tests/diarization_provider_boundary_smoke.swift`，覆盖 provider-neutral 请求/任务类型与不携带密钥字段的配置占位
- 新增 `docs/diarization-storage-decision.md`，记录真实 Fun-ASR 上传前必须选择 OSS 或 presigned URL service
- 新增 `Sources/DiarizationChunker.swift`，把 16kHz PCM16 音频按固定时长封存为单声道 WAV chunk
- chunker 使用串行队列异步写文件，`AudioRecorder` 的 ASR 数据回调仍先发送实时 ASR，再把同一份 PCM 数据交给 chunker，避免把文件 I/O 放到实时 ASR 发送路径上
- `AudioRecorder.stop()` 增加 `AudioTapDrainGate`，在释放 converter/recording file 前等待正在执行的 tap callback 结束，降低停止瞬间丢最后一段音频的风险
- 新增 `{session}.chunks.jsonl`，当前记录 `chunk_created` 和 `chunk_waiting_for_upload`；真实 provider 的 completed/failed 生命周期留到 fake/real provider 接入时补齐
- `MeetingViewModel` 在真实会议流里创建 `DiarizationAudioChunker`，停止会议时 flush 最后一个 partial chunk，并在 `.events.log` 写入 chunker start/finalized 事件
- 停止会议 finalize 前会补齐尚未写入 `.events.log` 的 chunk waiting 事件，避免最终 partial chunk 的等待上传事件排到 finalized 之后
- `AppConfig` 新增 `diarization.enabled`、`diarization.chunkDurationSeconds`，并支持 `MEETINGAI_SEGMENTED_DIARIZATION` / `MEETINGAI_DIARIZATION_CHUNK_SECONDS` 环境覆盖
- 新增 `tests/diarization_chunk_lifecycle_smoke.swift`，覆盖 WAV 输出、created/waiting JSONL、最终 partial chunk 封存和 home path 不进入 chunk log
- 新增 `tests/audio_recorder_drain_gate_smoke.swift`，覆盖 stop drain gate 会等待 in-flight tap callback
- `tests/run-p0-p1.sh` 接入 chunk lifecycle smoke，并新增 P1 检查确认 chunker 已接入会议流
- `scripts/run-real-meeting-smoke.sh` 固定短 smoke 的 diarization chunk 时长为 2 秒，并要求真实链路产出至少 2 个 chunk WAV，避免只验证 stop flush

### 验证
- RED：`swiftc Sources/AudioRecorder.swift tests/audio_recorder_drain_gate_smoke.swift -o .build/audio_recorder_drain_gate_smoke && ./.build/audio_recorder_drain_gate_smoke` → FAIL（`AudioTapDrainGate` 不存在）
- RED：`swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationBackfillWriter.swift tests/diarization_backfill_smoke.swift -o .build/diarization_backfill_smoke && ./.build/diarization_backfill_smoke` → FAIL（`Sources/DiarizationBackfillWriter.swift` 不存在）
- RED：`swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationBackfillWriter.swift tests/diarization_backfill_smoke.swift -o .build/diarization_backfill_smoke && ./.build/diarization_backfill_smoke` → FAIL（`eventLogURL` 参数不存在）
- RED：`swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift tests/diarization_provider_boundary_smoke.swift -o .build/diarization_provider_boundary_smoke && ./.build/diarization_provider_boundary_smoke` → FAIL（`Sources/DiarizationProviderBoundary.swift` 不存在）
- RED：`swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationChunker.swift tests/diarization_chunk_lifecycle_smoke.swift -o .build/diarization_chunk_lifecycle_smoke && ./.build/diarization_chunk_lifecycle_smoke` → FAIL（`Sources/DiarizationChunker.swift` 不存在）
- RED：`bash tests/run-p0-p1.sh` → FAIL（`P1-21 diarization chunker wired into meeting flow`）
- `swiftc Sources/AudioRecorder.swift tests/audio_recorder_drain_gate_smoke.swift -o .build/audio_recorder_drain_gate_smoke && ./.build/audio_recorder_drain_gate_smoke` → PASS
- `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationBackfillWriter.swift tests/diarization_backfill_smoke.swift -o .build/diarization_backfill_smoke && ./.build/diarization_backfill_smoke` → PASS
- `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift tests/diarization_provider_boundary_smoke.swift -o .build/diarization_provider_boundary_smoke && ./.build/diarization_provider_boundary_smoke` → PASS
- `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationChunker.swift tests/diarization_chunk_lifecycle_smoke.swift -o .build/diarization_chunk_lifecycle_smoke && ./.build/diarization_chunk_lifecycle_smoke` → PASS
- `bash tests/run-p0-p1.sh` → PASS
- `scripts/run-real-meeting-smoke.sh 90 75` → PASS，日志目录 `docs/runtime-logs/real-smoke-2026-05-23-17-47-00`，manifest 记录 `chunks_log_count=1`、`chunk_wav_count=1`
- chunk event ordering 修正后 `bash tests/run-p0-p1.sh` → PASS
- 多分片真实 smoke：`scripts/run-real-meeting-smoke.sh 90 75` → PASS，日志目录 `docs/runtime-logs/real-smoke-2026-05-23-17-53-36`，manifest 记录 `diarization_chunk_seconds=2`、`chunk_wav_count=5`
- `bash tests/run-all.sh` → PASS
- `git diff --check` → PASS
- 最终集中 GUI 回归：`bash tests/run-all.sh` → PASS
- 最终真实短 smoke：`scripts/run-real-meeting-smoke.sh 90 75` → PASS，日志目录 `docs/runtime-logs/real-smoke-2026-05-23-18-09-29`，manifest 记录 `diarization_chunk_seconds=2`、`chunk_wav_count=3`、`analysis_outcome=completed`

### 备注
- 真实上传存储和 Fun-ASR task polling 仍未接入；当前 chunk 状态会停在 `waitingForUpload`，`.diarized.jsonl` 由 fake/provider 结果写入
- 配置里只有 provider/storage 选择占位，没有 access key/secret key 字段
- 本轮已触及录音路径，真实短 smoke 已确认 `.chunks.jsonl` 和 chunk WAV 会随真实音频流产出

## 2026-05-23 - 分片说话人分离 OpenSpec 与合并核心

### 变更
- 新增 OpenSpec 变更 `openspec/changes/add-segmented-diarization/`，包含 proposal、design、spec delta 和 tasks
- 新增 `Sources/DiarizationModels.swift`，定义分片、任务状态、provider 句子和会话级说话人句子模型
- 新增 `DiarizationMerger`，把 chunk-local 时间戳转换成 session-relative 时间戳，并对重叠 chunk 的重复句子去重
- 新增 `tests/diarization_merge_smoke.swift`，覆盖时间偏移、乱序 task 完成排序、重叠去重并偏向后一个 chunk
- `tests/run-p0-p1.sh` 和 `docs/test-plan.md` 接入 diarization merge smoke
- 自审发现边界相接区间会被误判为重叠；新增回归测试后，将重叠判断修正为半开区间语义，避免误删重复短句
- 完整回归期间发现 fixture GUI 脚本偶发把已存在的 `AXButton` 计数为 0；脚本改为按 `role == AXButton` 枚举并点击 top bar 按钮，避免 AppleScript `buttons of group 1` 选择器竞态

### 验证
- 边界回归 RED：`swiftc Sources/Models.swift Sources/DiarizationModels.swift tests/diarization_merge_smoke.swift -o .build/diarization_merge_smoke && ./.build/diarization_merge_smoke` → FAIL（`touching intervals with repeated text should remain separate sentences`）
- `swiftc Sources/Models.swift Sources/DiarizationModels.swift tests/diarization_merge_smoke.swift -o .build/diarization_merge_smoke && ./.build/diarization_merge_smoke` → PASS
- `bash tests/run-p2-ui.sh` → PASS
- `bash tests/run-all.sh` → PASS
- `git diff --check` → PASS

### 备注
- 本轮仍未选择真实上传存储；实现只覆盖本地纯合并核心，不接 OSS 或 Fun-ASR 真实任务

## 2026-05-23 - 工程修复与经验沉淀

### 变更
- 新增 `docs/engineering-lessons-2026-05-23.md`，集中沉淀本轮中间修复、优化、根因、验证方式和后续守则
- 内容覆盖：事件日志恢复、ASR drain、重连去重、手动分析反馈、真实 smoke 误判修复、HTTP 响应解析、WAV fallback、partial/final 边界、说话人分离双轨方案

### 验证
- 文档更新，无需额外构建；引用的验证命令来自本轮已执行的 `bash tests/run-all.sh`、`scripts/run-real-meeting-smoke.sh 90 75`、`git diff --check`

## 2026-05-23 - 真实 smoke 修复与说话人分离方案确认

### 变更
- `AIEngine` 的 OpenAI-compatible HTTP 响应解析兼容 `message.content`、数组型 `content` 和 NVIDIA/Qwen 返回的 `message.reasoning_content`
- 新增 `tests/ai_response_parsing_smoke.swift`，覆盖标准响应、NVIDIA `reasoning_content`、数组文本和非法响应
- `AudioRecorder` 在 MP3 文件创建失败时自动 fallback 到同前缀 `.wav`，避免真实会议没有录音产物
- `scripts/run-real-meeting-smoke.sh` 增加 HTTP 后端环境覆盖、AI 分析完成等待、event log transcript 观测、非空录音产物检查和开始按钮失败诊断
- 新增调研文档 `docs/research/2026-05-23-diarization-segmented-transcription.md`：说话人分离采用分片录音 + Fun-ASR 非实时 HTTP，而不是塞进实时 Qwen-ASR 链路
- `README.md`、`docs/test-plan.md`、`docs/research/INDEX.md` 同步更新

### 验证
- `swift build` → PASS
- `swiftc Sources/Models.swift Sources/AIEngine.swift tests/ai_response_parsing_smoke.swift -o .build/ai_response_parsing_smoke && ./.build/ai_response_parsing_smoke` → PASS
- `scripts/run-real-meeting-smoke.sh 90 75` → PASS，日志目录 `docs/runtime-logs/real-smoke-2026-05-23-17-17-30`
- 真实 smoke manifest：`transcript_ready=1`、`analysis_outcome=completed`、`recording_count=1`

### 备注
- 当前实时 ASR 会在录音中间产出 partial；`.txt` 只写 final，所以 partial-only 长会仍必须依赖 `.transcript.md` 或后续 `TranscriptStore`
- 本机 MP3 编码不可用时已验证生成单声道 `.wav`，本次真实 smoke 产物中录音文件约 782KB
- 说话人分离的真实接入还需要先决策上传存储，因为 DashScope 文件转写需要可访问的 `file_urls`

## 2026-05-23 - 真实后端短 smoke 脚本

### 变更
- 新增 `scripts/run-real-meeting-smoke.sh`，用于短时间自动验证真实麦克风、DashScope ASR、当前 AI 配置与会话产物链路
- `MeetingViewModel` 支持 `MEETINGAI_ANALYSIS_BACKEND` 运行时环境覆盖，短 smoke 默认使用 `http` 后端以验证 `QWEN_API_KEY` 对应的在线模型链路
- 脚本独立使用临时 `MEETINGAI_SESSIONS_DIR`，采集 App stdout、Unified Log、bridge log 和 manifest 到 `docs/runtime-logs/{RUN_ID}/`
- 脚本只记录 `DASHSCOPE_API_KEY` / `QWEN_API_KEY` 是否存在，不输出 key 值
- `tests/run-p0-p1.sh` 增加短 smoke 脚本的可执行和语法检查；该脚本不进入默认 `tests/run-all.sh`，避免每次回归消耗真实 ASR/AI API
- `README.md` 与 `docs/test-plan.md` 补充短 smoke 和长彩排两层真实测试入口

### 验证
- `bash -n scripts/run-real-meeting-smoke.sh` → PASS
- `scripts/run-real-meeting-smoke.sh 90` → PASS，日志目录 `docs/runtime-logs/real-smoke-2026-05-23-16-50-33`
- 该次真实 smoke 观测到真实 ASR partial、`.events.log`、`.transcript.md`、`.ai.md`；无 final 转写，因此 `.txt` 为 0

### 备注
- `scripts/run-real-meeting-smoke.sh` 退出码 `0` 表示真实短链路通过；退出码 `2` 表示权限、麦克风输入或 API key 缺失等环境阻塞
- 16:50 这次 smoke 仍暴露一个真实彩排风险：默认 Hybrid 下 Codex CLI 洞察可能超过短 smoke 时间窗；短 smoke 后续固定 HTTP，20-30 分钟彩排再观察 Hybrid/Codex CLI 长耗时表现

## 2026-05-23 - 全量测试入口合并

### 变更
- 新增 `tests/run-all.sh`，统一执行 `tests/run-p0-p1.sh` 和 `tests/run-p2-ui.sh`
- `tests/run-p0-p1.sh` 增加全量入口脚本的可执行和语法检查
- `README.md` 与 `docs/test-plan.md` 将一键测试入口更新为 `bash tests/run-all.sh`

### 验证
- `bash -n tests/run-all.sh` → PASS

## 2026-05-23 - 手动分析限流反馈与真实彩排脚本

### 变更
- 手动点击“立即分析”时，如果 AI 正在分析，会追加系统提示“AI 正在分析中，请稍后再试。”
- 手动点击“立即分析”时，如果距上次分析未达到当前模式最小间隔，会追加系统提示“请 N 秒后再试”；自动触发仍只记录事件并静默跳过
- `analysis_skipped` 事件新增 `remainingSeconds`
- `tests/fixture_meeting_e2e.sh` 覆盖连续第二次手动分析点击，校验 UI 卡片数增加、`.ai.md` 有提示、`.events.log` 有 `source=manual/reason=min_interval`
- 新增 `scripts/run-real-meeting-rehearsal.sh`，用于真实测试时同时采集 unified log、bridge log、app stdout 和 session manifest
- `tests/run-p0-p1.sh` 增加真实彩排脚本语法检查

### 验证
- `swift build && bash tests/fixture_meeting_e2e.sh` → PASS
- `bash -n scripts/run-real-meeting-rehearsal.sh` → PASS

### 备注
- 真实 20-30 分钟麦克风 + 联网模型彩排需要现场说话和真实网络条件，本轮已提供一键采集脚本，但未伪造“已完成真实会议”的结论

## 2026-05-23 - ASR 重连去重与退避

### 变更
- `MeetingViewModel` 增加 ASR 重连状态机：同一时间只保留一个 pending reconnect task，重复错误只写 `asr_reconnect_deduplicated`
- 重连延迟从 1 秒开始指数退避，最高 16 秒；达到 `maxASRReconnects` 后写 `asr_reconnect_give_up` 并给用户明确提示
- ASR `session_started` 作为重连成功信号，写 `asr_reconnect_succeeded` 并重置重连计数和 backoff
- ASR client 回调用 generation guard 过滤旧连接的 late callback，避免旧连接错误干扰新连接状态机
- 停止会议时取消 pending reconnect，避免会议结束后继续拉起 ASR client
- 新增 `tests/asr_reconnect_policy_smoke.sh`，并接入 `tests/run-p0-p1.sh`
- 更新 `docs/test-plan.md` 的 P1/P2 ASR 重连验收描述

### 验证
- `bash tests/asr_reconnect_policy_smoke.sh` → PASS
- `swift build` → PASS
- `bash tests/run-p0-p1.sh` → PASS
- `bash tests/run-p2-ui.sh` → PASS

### 备注
- 本轮先收敛 App 侧状态机和日志，不声称已经覆盖真实 DashScope 长连接恢复质量
- 下一步真实彩排时需要人工触发或观察 bridge/network 断连，重点检查 `.events.log` 中是否出现 dedupe、backoff、give-up 或 session_started reset

## 2026-05-23 - 会话事件日志与 Markdown 转写恢复

### 变更
- 恢复每场会议同前缀的 `.events.log`，采用 JSON Lines 记录会议生命周期、配置摘要、ASR 客户端事件、转写事件、AI 分析触发/完成/失败、会话停止与产物路径
- 恢复每场会议同前缀的 `.transcript.md`，按当前 UI 转写列表写快照，并标记 `[最终]` / `[临时]`
- 停止会议提示中补充 `.transcript.md` 和 `.events.log` 路径
- `ASRClient` 增加轻量事件回调，便于 App 会话日志对齐 WebSocket 生命周期，不改变 ASR 协议
- `tests/fixture_meeting_e2e.sh` 扩展为校验 `.txt`、`.mp3`、`.ai.md`、`.events.log`、`.transcript.md` 五类产物，并为早期脚本失败增加诊断输出
- 同步更新 `README.md`、`docs/test-plan.md`、`docs/stage-review-2026-05-23.md`

### 验证
- `swift build` → PASS
- `bash tests/fixture_meeting_e2e.sh` → PASS
- `bash tests/run-p0-p1.sh && bash tests/run-p2-ui.sh` → PASS
- `bash tests/run-p2-ui.sh` → PASS（针对 GUI 重启/Accessibility 竞态修复后追加重跑）

### 备注
- `.events.log` 只记录凭证是否加载，不记录任何 API key 值
- `.txt` 仍保持原行为：只追加 final 转写；partial-only 场景由 `.transcript.md` 兜底保存当前可读快照
- 本轮未改 ASR 重连策略本身，重连去重/退避仍是下一项真实测试前任务

### 自审后修正
- 停止会议时增加 ASR drain 阶段：先停录音并发送 stop，等待客户端 grace window 后再停止 bridge、写最终 `.transcript.md` / `.ai.md` / `.events.log`，降低尾段 final 丢失风险
- `ASRClient` 的连接状态、音频 chunk 计数、WebSocket 引用改为串行队列保护，避免音频 tap、URLSession 回调、UI 停止操作并发读写
- fixture GUI 测试改为等待 3 条 fixture 转写全部出现，并校验 3 条 final event 与 3 条 Markdown 内容
- `.events.log` 字符串字段会把用户 home path 脱敏为 `~`

## 2026-05-23 - 阶段性回顾与真实测试准备

### 变更
- 新增 `docs/stage-review-2026-05-23.md`
- 汇总当前代码事实、历史问题、Claude Code compact 记录、API key 状态、真实运行日志与会话产物
- 明确真实测试前的日志补齐清单：`.events.log`、`.transcript.md`、ASR 重连去重/退避、手动分析限流提示

### 验证
- `bash tests/run-p0-p1.sh` → PASS
- `bash tests/run-p2-ui.sh` → PASS

### 备注
- 本轮未读取或写入任何 API key 值，只确认变量是否存在
- 发现历史真实会话产物包含 `.events.log` / `.transcript.md`，但当前源码已搜不到对应生成逻辑，后续真实测试前应优先确认并恢复

## 2026-03-27

### 变更
- 引入 `MeetingContextBuilder`，将会议上下文拆成 `hot window`、`近期背景`、`长期记忆`
- `MeetingViewModel.buildAnalysisUserContent()` 改为通过上下文快照构造 prompt
- README 增加 OpenSpec source-of-truth 入口
- `docs/test-plan.md` 增补上下文分层 smoke test
- `tests/run-p0-p1.sh` 新增 context builder smoke test

### 验证
- `swift build` → PASS
- `bash tests/run-p0-p1.sh` → PASS

### 备注
- 当前 toolchain 不提供 `XCTest`/`Testing` 模块，因此本轮使用 `swiftc + smoke test` 的可执行脚本作为自动验证方案
- 上下文压缩目前是结构化分层与预算裁剪，尚未引入基于 LLM 的长期记忆再总结

## 2026-03-27 - 闭环基础设施补齐

### 变更
- 新增 `.Codex/settings.json` 与 workflow hooks
- 新增 `tests/app_launch_smoke.sh`，验证原生 App 可启动且不会立刻崩溃
- 新增 `tests/ui_accessibility_precheck.sh`，自动检测 macOS GUI 自动化是否被系统权限阻塞
- 新增 `tests/gui_smoke.sh`，自动验证主窗口、顶部控件与设置 sheet
- 将 `docs/test-plan.md` 重写为当前 MeetingAI copilot 目标的闭环测试计划

### 验证
- `osascript -e 'tell application "System Events" to return UI elements enabled'` → `false`
- 结论：当前环境下 GUI 自动点击测试被系统 Accessibility 权限阻塞，不是应用代码崩溃

## 2026-03-27 - GUI smoke 落地

### 变更
- 将原生 GUI 自动化从“能力预检”推进到“可执行 smoke”
- GUI smoke 覆盖：窗口存在、标题文本存在、顶部业务按钮存在、gear 按钮可点击并弹出 settings sheet

### 验证
- `osascript -e 'tell application "System Events" to return UI elements enabled'` → `true`
- 通过 `System Events` 观察到 `MeetingAI` 进程窗口与业务 group
- 设置按钮点击后 `sheetCount = 1`

### 备注
- 当前已经具备原生 macOS GUI 自动化基础
- 但“开始会议 -> 录音 -> 转写 -> 手动分析”这条完整 E2E 仍未自动化，因为它会引入麦克风、ASR 进程和模型调用的额外不稳定性

### 备注
- Android `maestro` / `adb` 流程与当前 macOS 自动化方案不直接冲突
- 若后续启用 Accessibility，可继续把 P2-A 从预留方案升级成真正自动 GUI 测试

## 2026-03-27 - GUI smoke 稳定化

### 变更
- 修复 `tests/gui_smoke.sh` 中对 SwiftUI 可访问树的错误假设
- 不再直接抓取 `static text` 子集，改为读取 `group 1 of window 1` 的顶层 `UI elements`
- 将窗口出现、顶栏文本校验、按钮数量校验、settings sheet 弹出拆成独立步骤并加入重试

### 验证
- `bash tests/gui_smoke.sh` → PASS
- `bash tests/run-p0-p1.sh` → PASS

### 备注
- 这轮失败不是权限问题，而是 AppleScript 查询路径不稳定
- 当前闭环基线已经包含真实的 macOS GUI 点击 smoke，但仍只覆盖“启动 App -> 识别顶栏 -> 打开设置”这一层

## 2026-03-27 - P2 GUI workflow 批处理

### 变更
- 新增 `tests/meeting_toggle_smoke.sh`，自动验证“开始会议 -> 出现录音中/计时器 -> 停止会议 -> 状态清除”
- 新增 `tests/run-p2-ui.sh`，统一执行当前可自动化的 GUI workflow 批次
- 将 `docs/test-plan.md` 的 P2-A 状态同步到已验证结果

### 验证
- `bash tests/meeting_toggle_smoke.sh` → PASS
- `bash tests/run-p2-ui.sh` → PASS

### 备注
- 这轮改成批量执行后，验证效率明显高于逐步探针式试错
- 短会话结束后当前稳定观测到新增 `.ai.md`，但未稳定观测到 `.txt` / `.mp3` 文件；这更像待确认的产品行为或缺陷，不纳入当前自动 smoke 的通过条件

## 2026-03-27 - Fixture E2E 闭环

### 变更
- 为关键控件补充 accessibility 标识，减少 GUI 自动化对偶然层级的依赖
- 在 `AppConfig` 中加入 `MEETINGAI_UI_FIXTURE` 和 `MEETINGAI_SESSIONS_DIR` 支持
- 在 `MeetingViewModel` 中加入 fixture meeting 启动路径，跳过真实麦克风、ASR 和外部模型
- 在 `AIEngine` 中加入 deterministic fixture 响应，稳定产出测试洞察
- 新增 `tests/fixture_meeting_e2e.sh`，覆盖“开始会议 -> fixture 转写 -> 立即分析 -> 结束会议 -> 校验 txt/mp3/ai.md”
- 更新 `tests/run-p0-p1.sh`，补充新脚本存在性检查，并为 GUI smoke 增加一次重试

### 验证
- `swift build` → PASS
- `bash tests/fixture_meeting_e2e.sh` → PASS
- `bash tests/run-p0-p1.sh` → PASS
- `bash tests/run-p2-ui.sh` → PASS

### 备注
- 当前已经具备不依赖真实硬件和外部 API 的 GUI 闭环测试主路径
- 真实麦克风 / 实时 ASR / 联网模型仍然属于更高成本的集成层，不纳入默认自动批次

## 2026-03-27 - Analysis backend benchmark and routing

### 变更
- 新增 `tests/benchmark_analysis_backends.py`，对比当前 HTTP 模型与 Codex CLI 的延时和输出质量
- 将 benchmark 结果沉淀到 `docs/research/2026-03-27-analysis-backend-benchmark.md`
- 新增 `AnalysisBackendMode`，支持 `HTTP / Codex CLI / Hybrid`
- `AIEngine` 新增 backend 路由与 Codex CLI 调用能力，并在 Codex 失败时自动回退 HTTP
- `SettingsView` 新增分析后端切换
- GUI 测试脚本新增旧实例清理，避免被手动运行的 App 污染

### 验证
- `python3 tests/benchmark_analysis_backends.py` → PASS
- `bash tests/run-p0-p1.sh && bash tests/run-p2-ui.sh` → PASS

### 备注
- 本地 benchmark 显示：summary 更适合留在 HTTP，insight 更适合交给 Codex CLI
- 当前默认策略是 `Hybrid`

## 2026-03-27 - Backend visibility and logging review

### 变更
- 在右侧 `AI 洞察` 面板增加后端状态行，显示当前配置后端、正在分析中的后端，以及最近一次执行状态
- 在每张洞察卡片上增加后端 badge 和执行状态，明确标出 `Codex CLI / HTTP / 回退`
- 修正 `MeetingViewModel` 的 AIEngine 刷新逻辑，保证设置里的 backend 改动在会议过程中也会真实生效，不会出现“界面显示已切换但实际仍走旧后端”
- 清理初始化时输出 API Key 前缀的日志，改为只记录凭证是否已加载
- 补齐 `开始分析 -> 选路 -> Codex 启动 -> 回退 -> 卡片落地 -> 会话文件落盘` 关键节点日志
- 将面向用户的 AI 错误文案改成简洁中文，同时把原始错误细节继续保留在日志里
- 会话结束写出的 `.ai.md` 现在包含每条卡片对应的执行后端与状态摘要

### 验证
- `swift build` → PASS
- `bash tests/run-p0-p1.sh && bash tests/run-p2-ui.sh` → PASS

### 备注
- 当前 UI 已具备“看得到后端、看得到回退、看得到最近失败”的基本可观测性
- 日志侧重点放在关键状态转移和失败分支，不追求把每一条普通转写都打成高频噪声

## 2026-03-27 - GUI batch strategy simplification

### 变更
- 将默认 `P2` 批次从“多个细粒度 GUI 脚本串跑”改成“一条粗粒度 fixture 主路径”
- `tests/fixture_meeting_e2e.sh` 现在一次性覆盖窗口出现、设置 sheet、开始会议、录音状态、fixture 转写、手动分析、后端状态可见、结束会议和产物校验
- `tests/gui_smoke.sh` 和 `tests/meeting_toggle_smoke.sh` 保留为定点排查脚本，但不再放在默认批次里
- `tests/run-p0-p1.sh` 去掉了重复的 GUI smoke，避免默认全量回归时反复切换界面
- `docs/test-plan.md` 已同步新的“粗粒度优先，细粒度按需”策略

### 验证
- `bash tests/run-p0-p1.sh && bash tests/run-p2-ui.sh` → PASS

### 备注
- 这样默认回归更接近真实用户路径，也更省时
- 如果后续主路径里某一段开始抖动，再退回细粒度脚本定位，而不是一开始就把默认策略切得很碎
