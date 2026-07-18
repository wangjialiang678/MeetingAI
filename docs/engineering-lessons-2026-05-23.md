# MeetingAI 工程修复与经验沉淀

日期：2026-05-23

## 背景

本轮目标是把项目推进到真实会议前可测试状态：补齐会话日志、恢复会后转写产物、收敛 ASR 重连、跑通真实麦克风 + 在线模型短链路，并对新增的说话人分离需求做技术判断。

这份文档记录中间过程中的优化、修复和经验，供后续开发避免重复踩坑。

## 修复与优化清单

| 项 | 现象 / 风险 | 根因 | 修复 | 验证 |
|---|---|---|---|---|
| 会话级日志缺失 | 真实会议出问题后无法复盘 | 当前源码缺少历史 `.events.log` / `.transcript.md` 生成逻辑 | 恢复每场同前缀 `.events.log` JSON Lines 和 `.transcript.md` 快照 | `tests/fixture_meeting_e2e.sh` 校验事件和 Markdown 产物 |
| API key 泄露风险 | 日志和文档可能误写密钥 | 真实测试需要检查 key 存在，但不需要值 | 只记录 `DASHSCOPE_API_KEY` / `QWEN_API_KEY` 是否存在；event log 中 home path 脱敏 | 搜索真实产物确认没有 key 值或 home path 明文 |
| 停止会议尾段丢失 | stop 后马上停 bridge，尾段 final/finished 可能来不及回传 | ASR disconnect 和 session finalize 没有 drain window | 停止录音后先等待 ASR client grace period，再 finalize 文件 | fixture E2E 等待完整 final 事件；真实 smoke 观测 `meeting_stopped` |
| ASR 重连刷屏 | 长会日志出现大量 ASR error/reconnect | 没有 pending reconnect 去重和退避状态 | 增加单一 pending task、指数退避、give-up、session_started reset | `tests/asr_reconnect_policy_smoke.sh` |
| 旧连接 late callback 干扰 | 重连后旧 ASR client 仍可能回调错误 | 回调没有区分连接代际 | 加 `asrClientGeneration` guard | `tests/asr_reconnect_policy_smoke.sh` |
| 手动分析无反馈 | 用户连续点“立即分析”会以为按钮坏 | min interval 只写 debug 并 return | 手动触发时追加系统提示，自动触发仍静默跳过 | fixture E2E 校验 UI 卡片、`.ai.md`、`.events.log` |
| 默认 GUI 测试重复 | 多个小 GUI smoke 反复启动窗口，慢且不稳定 | 测试入口没有合并主路径 | 新增 `tests/run-all.sh`，P2 使用单个 fixture 主流程 | `bash tests/run-all.sh` |
| 真实 smoke 误判 stop 失败 | 会话有 `meeting_started`，但缺 `meeting_stopped` | AppleScript 按钮索引在录音状态变化后不稳定 | 优先按可访问名称点击，索引仅作为 fallback；显式等待录音状态清除 | `scripts/run-real-meeting-smoke.sh` |
| 真实 smoke 误判无转写 | UI 可访问树没有及时暴露条数，但 event log 已有 partial | smoke 只看 UI 文本 | 转写就绪改为 UI 或 `.events.log` 任一观测到 transcript 事件 | 最新真实 smoke PASS |
| Hybrid 短 smoke 不稳定 | 默认 Hybrid 可能走 Codex CLI，短时间内不一定完成 | 洞察在 Hybrid 下优先走本机 Codex CLI | 增加 `MEETINGAI_ANALYSIS_BACKEND=http` 环境覆盖，短 smoke 默认验证 HTTP | `scripts/run-real-meeting-smoke.sh 90 75` |
| Qwen/NVIDIA 响应解析失败 | HTTP 200，但 App 报“模型响应解析失败” | NVIDIA compatible endpoint 返回 `message.reasoning_content`，`message.content` 为 null | HTTP 解析兼容 `content`、数组 content、`reasoning_content` | `tests/ai_response_parsing_smoke.swift` + 真实 smoke |
| 真实录音文件缺失 | Unified Log 显示 MP3 创建失败，会后无可用录音 | macOS 当前环境下 `AVAudioFile` MP3 encoder 不可用 | MP3 失败时 fallback 到单声道 WAV，并删除半成品 | 真实 smoke 产出非空 `.wav` |
| `.txt` 不完整 | 真实 ASR 多次只有 partial，`.txt` 为 0 | `.txt` 只追加 final | 暂不把 `.txt` 视作完整转写来源；`.transcript.md` 保存 partial 快照 | 真实 smoke 中 `finalEntries=0` 但 `.transcript.md` 有内容 |
| 说话人分离路线不清 | 用户需要录音转录说话人分离，不是实时语音 | 当前实时 Qwen-ASR 不支持 diarization | 调研确认采用双轨：实时 ASR + 分片 Fun-ASR 非实时文件识别 | `docs/research/2026-05-23-diarization-segmented-transcription.md` |
| 分片去重误删边界句 | 相邻分片边界两句文本相同会被当成重复 | 用闭区间判断重叠，`end == begin` 被算作重叠 | 改为半开区间语义，只在真实交叠时去重 | `tests/diarization_merge_smoke.swift` 边界回归 |
| GUI fixture 偶发按钮计数为 0 | UI dump 有 `AXButton`，但 `count of buttons of group 1` 返回 0 | SwiftUI Accessibility 与 AppleScript 类型选择器有竞态 | 改为枚举 `UI elements` 并按 `role == AXButton` 过滤点击 | `bash tests/run-p2-ui.sh` |
| 分片写文件影响实时链路风险 | 会议中要持续封存 chunk，但实时 ASR 不能被文件 I/O 卡住 | 音频 tap 回调对延迟敏感 | chunker 使用串行队列异步写 WAV；实时回调先发送 ASR，再投递 chunk 写入 | `tests/diarization_chunk_lifecycle_smoke.swift` + `bash tests/run-p0-p1.sh` |
| stop 时丢最后音频尾巴风险 | 停止录音后立即 finalize chunker，仍在执行的 tap callback 可能晚到 | `removeTap` 不等于等待当前 callback 完成 | 增加 `AudioTapDrainGate`，stop 时先 drain callback，再释放 recorder 资源和 finalize chunk | `tests/audio_recorder_drain_gate_smoke.swift` + 多分片真实 smoke |
| speaker 回填覆盖原文风险 | 后处理说话人标签可能破坏实时转写事实 | 归档轨结果与实时轨事实混在同一内容区 | `.diarized.jsonl` 独立保存，`.transcript.md` 只追加“说话人分离回填”区块，不改原始逐条记录 | `tests/diarization_backfill_smoke.swift` |
| provider 接入硬编码密钥风险 | 文件转写需要可访问 URL，容易直接把 OSS 密钥塞进配置 | 上传存储还没决策 | 只加 provider/storage 占位和 uploader protocol，真实存储决策写入 `docs/diarization-storage-decision.md` | `tests/diarization_provider_boundary_smoke.swift` |
| OSS/Fun-ASR 接入泄露签名 URL 风险 | 预签名 URL query 等同临时访问凭证 | 事件日志若直接写 remote URL 会包含 `x-oss-signature` | pipeline 日志只写 host/path，丢弃 query；真实 smoke 增加 secret-like grep | `tests/fun_asr_provider_smoke.swift` + `tests/diarization_pipeline_smoke.swift` |
| 桌面 App 读取不到 shell env 风险 | GUI App 不一定继承终端环境变量 | 依赖只读 `ProcessInfo.environment` 会导致真实会议无 OSS 凭证 | `AppConfig` 同时读取 process env 和 `~/.claude/api-vault.env`，但只记录 credentialLoaded 布尔值 | `swift build` + P0/P1 |
| 云端说话人 ID 被过度解释风险 | Fun-ASR 返回 `speaker_id`，但官方未承诺跨分片稳定 | 每个 chunk 独立转写可能重新编号 | 文档明确不把 speaker-0 解释成全会固定真人；后续需要跨 chunk speaker linking 才能升级语义 | `docs/research/2026-05-23-diarization-segmented-transcription.md` |
| 后续 Markdown 快照擦掉回填 | Fun-ASR 已写入“说话人分离回填”，后续 ASR/stop 快照又覆盖 `.transcript.md` | 快照 writer 只知道实时逐条记录，不知道 speaker backfill 区块 | 抽出 `TranscriptMarkdownWriter`，快照会保留已有回填；有新 segments 时替换旧回填 | `tests/transcript_markdown_writer_smoke.swift` |
| 旧会话异步回调污染新会议 | 用户快速开始下一场时，上一场 Fun-ASR 任务可能晚返回并更新当前 UI | 任务 handle 被清空，回调没有会话代际 | 增加 `DiarizationSessionGate`；新会议生成 token，旧 token 回调不再更新 `speakerBackfillSegments` | `tests/diarization_session_gate_smoke.swift` |
| Fun-ASR UNKNOWN 轮询到超时 | 云端返回 `UNKNOWN` 时继续 sleep/poll，浪费真实测试时间 | 把 `UNKNOWN` 当成 pending 类状态处理 | `UNKNOWN` 改为快速失败，并在错误中保留状态名 | `tests/fun_asr_provider_smoke.swift` |
| 真实 Fun-ASR smoke 过早成功 | 只要一个 chunk 完成就判成功，可能掩盖后续 chunk 失败 | 成功条件没有和 finalized chunk 总数对齐 | 抽出 `funasr_outcome_from_logs`，失败优先，只有所有 finalized chunks 完成才 PASS | `tests/real_meeting_smoke_fun_asr_outcome.sh` |

## 关键经验

### 1. 真实链路测试要区分 PASS / FAIL / BLOCKED

真实麦克风、macOS Accessibility、外部 ASR、在线模型都可能受环境影响。脚本必须清楚区分：

- `PASS`：产品链路和断言都通过。
- `FAIL`：代码或协议行为不满足断言。
- `BLOCKED`：权限、输入设备、API key、窗口自动化等环境前置不满足。

不要把 BLOCKED 当 PASS，也不要把环境阻塞伪装成代码失败。

### 2. 事件日志比 UI 自动化更适合作为真实测试判据

SwiftUI Accessibility 树会有延迟、层级漂移和按钮索引变化。真实 smoke 可以用 UI 完成操作，但判断业务结果时应优先看 `.events.log`：

- 是否 `meeting_started`
- 是否出现 `asr_client_session_started`
- 是否出现 `transcript_partial` / `transcript_final`
- 是否 `analysis_completed` / `analysis_failed`
- 是否 `meeting_stopped`

UI 文本适合补充验证，不适合做唯一事实来源。

### 3. partial 必须成为一等公民

真实 ASR 会长时间只产出 partial，final 可能只在断句、停止或服务端判定句末时出现。后续不要把“完整转写”等同于 `.txt`：

- UI 和 AI 触发应使用 partial + final。
- 会后复盘至少依赖 `.transcript.md`。
- 下一步应抽象 `TranscriptStore`，让 final-only `.txt` 降级为兼容产物。

### 4. 兼容接口不能只按 OpenAI happy path 写

OpenAI-compatible 不代表响应字段完全一致。本轮 NVIDIA/Qwen 返回正文在 `message.reasoning_content`，`message.content` 为 null。以后接入 compatible endpoint 时，至少要做：

- 最小 curl 验证真实响应结构。
- 本地 parser smoke 覆盖非标准字段。
- 日志记录结构性错误，但不输出完整敏感请求。

### 5. macOS 音频编码能力要用真实运行验证

`AVAudioFile` 能写某种格式不代表当前机器一定支持该 encoder。真实 smoke 发现 MP3 创建失败后，单声道 WAV fallback 更适合当前阶段：

- WAV 更稳定。
- Fun-ASR 说话人分离要求单声道音频，单声道 WAV 更接近后续接口要求。
- 录音产物检查应确认文件非空，而不只检查路径存在。

### 6. 短 smoke 应验证一条明确链路，不要混入高延迟策略

短 smoke 的目标是快速确认麦克风、ASR、HTTP AI 和会话产物。默认 Hybrid 会把洞察交给 Codex CLI，延迟和本机 CLI 状态会污染短链路判断。因此短 smoke 固定 `MEETINGAI_ANALYSIS_BACKEND=http` 是合理的；Hybrid/Codex CLI 应放到 20-30 分钟真实彩排里观察。

### 7. 真实会议能力要拆实时轨和归档轨

实时 ASR 适合低延迟 UI 和 AI 提醒；说话人分离适合文件级后处理。把两者硬塞进一条实时链路会同时损害延迟、稳定性和可复盘性。下一阶段应采用：

- 实时轨：Qwen-ASR WebSocket，产出 partial/final。
- 归档轨：录音 chunk -> 上传 -> Fun-ASR HTTP diarization -> merge/backfill。

### 8. 新脚本要把日志目录作为一等输出

每个真实测试脚本都应该写 `docs/runtime-logs/{RUN_ID}`，至少包含：

- `manifest.txt`
- App stdout
- Unified Log
- bridge log
- session 文件清单

失败时只给“失败”没有意义，必须留下足够复盘的上下文。

### 9. 分片去重要优先避免误删

说话人分离分片合并的去重目标是消除 overlap 区域的重复句，不是合并所有相似文本。时间段应按半开区间 `[begin, end)` 处理：

- `max(begin) < min(end)` 才是真实重叠。
- `end == begin` 只是边界相接，不能去重。
- 对会议记录来说，少量重复比误删真实发言更容易接受。

### 10. 分片链路要与实时链路解耦

录音分片是归档轨能力，不能把文件写入、上传、provider polling 放到实时 ASR 的关键路径上。当前做法是：

- `AudioRecorder` 继续输出 16kHz PCM16 给实时 ASR。
- `MeetingViewModel` 先把 PCM 数据送 ASR，再交给 `DiarizationAudioChunker`。
- chunker 内部用串行队列写 WAV 和 `.chunks.jsonl`。
- provider 未配置时只记录 `waitingForUpload`，不伪造上传成功。
- stop 时先 drain 正在执行的音频 tap callback，再 finalize chunker，避免尾段 PCM 晚到后被忽略。
- 说话人标签回填只追加新章节，不覆盖实时 transcript 原文；机器后处理结果和实时事实必须可分辨。
- 真实 provider 前必须先选上传存储边界；桌面 app 配置只放 provider/storage 选择，不放密钥。
- OSS 上传使用官方 Swift SDK，不手写 V4 签名；临时 GET 预签名 URL 只进内存请求，不进 `.events.log` / `.chunks.jsonl`。
- Fun-ASR 的 `transcription_url` 有时效性，任务成功后要立即下载并本地回填，不依赖未来重复下载。

## 后续实现守则

1. 先做 `TranscriptStore`，再做说话人分离 UI。
2. 先做本地 chunk lifecycle 和 fake diarization merge，再接真实上传。
3. 分片文件默认单声道 WAV；不要依赖 MP3。
4. DashScope 文件转写需要可访问 URL；当前个人原型采用私有 OSS + GET 预签名 URL，后续多用户化再考虑 presigned URL service。
5. 分片结果回填不能覆盖实时转写事实，应以新层级写入 `.diarized.jsonl` 和 `.transcript.md`。
6. chunk 边界必须有 overlap 和去重策略，否则说话人句子会在边界断裂；去重必须按半开区间判断，不能误删边界相接句子。
7. 所有真实测试都必须写 `.events.log`，并把 API key 值排除在日志之外。
8. 真实 Fun-ASR smoke 使用 `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1` 单独打开，缺 bucket/OSS 凭证时应返回 BLOCKED，而不是污染日常 P0/P1。

## 已验证命令

```bash
bash tests/run-all.sh
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationChunker.swift tests/diarization_chunk_lifecycle_smoke.swift -o .build/diarization_chunk_lifecycle_smoke && ./.build/diarization_chunk_lifecycle_smoke
swiftc Sources/AudioRecorder.swift tests/audio_recorder_drain_gate_smoke.swift -o .build/audio_recorder_drain_gate_smoke && ./.build/audio_recorder_drain_gate_smoke
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationBackfillWriter.swift tests/diarization_backfill_smoke.swift -o .build/diarization_backfill_smoke && ./.build/diarization_backfill_smoke
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift tests/diarization_provider_boundary_smoke.swift -o .build/diarization_provider_boundary_smoke && ./.build/diarization_provider_boundary_smoke
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationFunASRProvider.swift tests/fun_asr_provider_smoke.swift -o .build/fun_asr_provider_smoke && ./.build/fun_asr_provider_smoke
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationBackfillWriter.swift Sources/DiarizationFunASRProvider.swift Sources/DiarizationPipeline.swift tests/diarization_pipeline_smoke.swift -o .build/diarization_pipeline_smoke && ./.build/diarization_pipeline_smoke
swiftc Sources/DiarizationModels.swift Sources/DiarizationOSSSupport.swift tests/diarization_oss_support_smoke.swift -o .build/diarization_oss_support_smoke && ./.build/diarization_oss_support_smoke
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/TranscriptMarkdownWriter.swift tests/transcript_markdown_writer_smoke.swift -o .build/transcript_markdown_writer_smoke && ./.build/transcript_markdown_writer_smoke
swiftc Sources/DiarizationSessionGate.swift tests/diarization_session_gate_smoke.swift -o .build/diarization_session_gate_smoke && ./.build/diarization_session_gate_smoke
bash tests/real_meeting_smoke_fun_asr_outcome.sh
scripts/run-real-meeting-smoke.sh 90 75
git diff --check
```

最新真实 smoke：`docs/runtime-logs/real-smoke-2026-05-23-18-09-29`。
