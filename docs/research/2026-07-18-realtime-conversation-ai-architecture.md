---
title: 2026 年中实时对话理解 + 建议架构调研
date: 2026-07-18
status: active
audience: both
tags: [research, realtime-voice, architecture, asr, diarization, cost-analysis]
type: 原始调研
sources: [OpenAI docs, Google AI docs, Alibaba Cloud Model Studio, Zhipu/Z.ai docs, arxiv, LiveKit/Pipecat blogs, GitHub FluidAudio, Deepgram/AssemblyAI, Apple WWDC25]
verified: 2026-07-18
shelf_life: 快速变化
---

# 调研报告: 2026 年中实时对话理解 + 建议架构

**日期**: 2026-07-18
**任务**: 为 MeetingAI 下一版"会议中 AI 实时给建议"场景，评估音频原生模型 vs 级联管线、级联最佳实践、本地端侧组件、实时说话人分离、8 小时/天持续旁听的成本量级，回答"2026 年中做实时对话理解+建议，最佳架构是什么"。

---

## 调研摘要

2026 年中的行业共识（多篇 2026 年 3-7 月的一手来源，含 2 篇 arxiv 论文和 LiveKit/Pipecat/Modulate 等厂商实测）是：**生产级语音 agent 仍以级联管线（流式 ASR → 文本 LLM → 可选 TTS）为默认选择，音频原生 S2S 模型只在"自然度是产品本身"的场景才优先**。这个结论对 MeetingAI 尤其成立，原因有三：(1) 商用音频原生 API（OpenAI Realtime、Gemini Live、GLM-Realtime、Qwen-Omni-Realtime）全部按"单用户轮流对话"设计，服务端 VAD/语义 VAD 期望"一个人说完、模型说回去"，并不天然支持"持续旁听多人对话、只在值得时才吐出文字卡片"这种场景；(2) 结构化输出/工具调用在 S2S 模型上仍明显弱于纯文本 LLM，这对"输出洞察卡片 JSON"是硬需求；(3) 8 小时/天持续旁听场景下，OpenAI Realtime 全时段常开的成本量级是级联方案的 15-100 倍，Gemini Live 在"仅要文字输出、几乎不要语音输出"的配置下勉强能打平级联方案，但需要专项验证中文效果和多人转写质量后才能下注。

对 MeetingAI 当前架构最有价值的两个新发现：一是 Apple Silicon 上已有成熟的本地流式说话人分离方案 **FluidAudio**（Swift SDK，ANE 加速，M1 上实测 0.017 RTF/60x 实时，已被同品类竞品 Hedy 生产使用），理论上可以把现在"分片→OSS→Fun-ASR 非实时→回填"的归档轨换成本地近实时轨，但中文准确率未经验证；二是当前 `AIEngine.swift` 用的是非流式整段 HTTP 请求、`MeetingContextBuilder.swift` 每次都重新拼接完整 prompt，这是比"要不要换模型架构"更立即可落地的延迟优化点（改流式渲染 + 利用 Zhipu 已支持的 prompt 缓存）。

---

## 现有代码分析

### 相关文件
- `Sources/AIEngine.swift` — 当前 HTTP 后端是非流式整段 POST（`analyze` 直接 await 完整响应），未使用 SSE 流式渲染，也未显式利用 prompt 缓存前缀。
- `Sources/MeetingContextBuilder.swift` — 每次分析都重新拼接 hot window（10 分钟）/ recent window（30 分钟）/ 长期记忆三段式 prompt，字符预算固定（hotBudget 2800 / recentBudget 1800 / durableBudget 1400），触发逻辑在上层按字数/沉默阈值（见 CLAUDE.md 表格）。
- `asr-bridge/`（Go 子进程）+ `Sources/ASRClient.swift` — 当前用 DashScope `qwen3-asr-flash-realtime`（流式 WebSocket ASR），本次调研确认其官方计价为 0.00033 元/秒（中国内地），是本报告成本对比的基线之一。
- `Sources/Diarization*.swift` — 归档轨是"分片 WAV → OSS → Fun-ASR 非实时 HTTP → LLM 交叉纠错 → merge → 回填"，属于典型非实时批处理设计，是本次"实时说话人分离能否替代"问题的直接对照对象。

### 现有模式
- 触发机制是字数阈值 + 沉默阈值（机械规则），不是语义事件触发；2026-05-23 的调研报告已经指出这是缺口（`docs/research/2026-05-23-proactive-meeting-agent-private-board-coach.md`），本次调研的"语义 VAD / 语义 turn detection"发现可以直接喂给那个缺口。
- AI 分析走非流式 HTTP，用户感知延迟 = 网络 + 完整生成时间，没有"边生成边显示"的流式渲染。

### 可复用组件
- 无直接可复用的第三方组件（本项目是 Swift 原生栈，多数调研到的开源项目是 Python/TS 生态），但 FluidAudio（Swift/CoreML/ANE）在技术栈上原生适配，是本次调研里唯一可以直接考虑接入的开源项目。

---

## 技术方案

### 问题 1：音频原生模型 vs 级联管线

**音频原生模型现状（2026-07 价格/能力，均为官方文档或官方定价页确认）**

| 模型 | 定位 | 价格（官方） | 延迟 | 备注 |
|---|---|---|---|---|
| OpenAI `gpt-realtime-2.1` | 语音转语音，5.4 代推理 | 音频输入 $32/M tokens、缓存输入 $0.40/M、音频输出 $64/M（约合 $0.077/min 输入 + $0.154/min 输出，典型通话约 $0.23/min） | p50 ~300ms（官方基准） | 2026-05 起每约 2 个月一次生产迭代节奏 |
| OpenAI `gpt-realtime-2.1-mini` | 蒸馏轻量版 | 音频输入 $10/M、输出 $20/M，约为旗舰版 1/3 | 相近 | — |
| Google `gemini-3.1-flash-live-preview` | 音频转音频，同时吃视频/图像 | 音频输入 $3/M tokens 或 $0.005/min；输出 $12/M 或 $0.018/min | Preview，官方未给固定端到端延迟数字 | 官方最佳实践要求 20-40ms 小块流式发送，不要缓冲 |
| 阿里 `qwen3.5-omni-flash-realtime`（中国内地） | 端到端语音，Thinker-Talker 架构 | 文本输入 $0.45/M，音频输入 $3.71/M；文本+音频输出 $2.75/M / $14.71/M | 未公开端到端延迟基准 | Plus 版更贵（音频输入 $11/M） |
| 智谱 `GLM-Realtime`（Flash / Air） | 音视频通话模型 | Flash 0.18 元/分钟（音频），Air 0.3 元/分钟；视频通话另计 1.2-2.1 元/分钟 | 未公开基准 | **上下文仅 8K token，通话记忆约 20 轮/2 分钟** — 对小时级会议不够用 |
| StepFun `Step-Audio R1.1`（开源，Apache-2.0） | Dual-Brain 架构，推理与发声分离 | 自托管 | Artificial Analysis 测得 TTFT ~1.51s | Big Bench Audio 榜首（~97%），但 TTFT 本身已超过"几秒内出现"的预算 |
| Moonshot `Kimi-Audio` | 开源音频基座模型 | 自托管 | — | LibriSpeech WER 1.28%（2026 年初 SOTA），偏 ASR 质量而非对话延迟 |

**反方证据（音频原生替代级联不可行/不成熟）**

1. arxiv《Building Enterprise Realtime Voice Agents from Scratch》（2026-03，2603.05413）系统实测：原生 S2S 模型（如 Qwen2.5-Omni）"太慢，不适合实时交互（首字延迟约 13 秒）"；行业标准是流式级联（ASR→LLM→TTS），作者自建的级联管线 P50 首字节延迟仅 947ms（最优 729ms），且是唯一支持工具调用的架构层级。
2. arxiv《The Cascade Equivalence Hypothesis》（2026-03，2602.17598）机制分析：语音 LLM 实际上表现为"隐式 ASR→LLM 级联"，其内部隐藏状态里必然出现文字转写表征，且**噪声条件下显式级联比端到端音频模型准确率高出最多 7.6 个百分点**。
3. LiveKit 官方对比《Pipeline vs. Realtime》：级联架构在"要不要调用工具"上决策更准，因为纯文本 function calling 是"经过多年打磨的成熟机制"；S2S 的工具调用"边听边想边说"同时进行，"部分参数在打断时" "结构化输出校验"等边界情况仍在收敛中。
4. Modulate.ai《Beat the Black Box》白皮书：优化后的流式级联可做到 P50 947ms / 最优 729ms 首字延迟，"完全在对话舒适区内"；S2S 因为链路上没有逐阶段文本日志，可观测性和可调试性显著更差。
5. Gradium（Moshi 团队）2026-05 博客直言："2026 年，生产环境的选择是级联。S2S 的优势是真实的，但还没有达到生产级、可运营的形态。"
6. LiveKit 2026 Playbook 给出的经验法则："默认用级联，只有'自然度就是产品本身'时才上 S2S；混合架构才是 2026 年的模式。"

**MeetingAI 场景的结构性错配（本节为综合推理，非单一来源直接结论，标注为推测）**

商用 S2S API 全部按"单用户轮流对话"设计：服务端 VAD/语义 VAD 判断"用户说完了"，然后模型生成语音回复。GLM-Realtime 的官方 session 示例里能看到 `voice`、`instructions`（拟人人设）等字段，本质是对话 agent 构造，不是被动多人监听器。要把这些 API 用于"持续旁听多人对话、只偶尔吐文字卡片、不需要模型开口说话"的场景，必须退化到"仅要转写"模式（如 Gemini 的 `input_audio_transcription`、OpenAI 的转写专用端点），这本质上是把音频原生 API 降级成了一个流式 ASR 服务——并没有消除级联，只是把 ASR 换了个更贵的供应商，同时还要另起一个文本 LLM 做"值不值得说"的判断。旁证：即便是专门为"被动旁听"设计的产品类别（如医疗 ambient AI 临床记录），其技术栈说明依然是"流式 ASR + 结构化笔记生成"的级联模式，不是 S2S 对话 API（Speechmatics 的 Ambient AI 文章）。

**结论**：音频原生模型目前不适合作为 MeetingAI 的主链路架构。**唯一值得后续做技术验证（spike）的例外是 Gemini 3.1 Flash Live 的"音频输入/文本输出"模式**——Google 官方文档明确支持 20-40ms 小块连续流式发送（架构上比 OpenAI/GLM 的对话式框架更接近"旁听"），且价格（输入 $0.005/min）在只要文字、几乎不要语音输出的配置下与现有级联方案量级相当。但中文效果、多人转写质量、能否真正关闭轮流对话式的服务端判定，均未在本次调研中验证。

### 问题 2：级联管线的最佳实践

**延迟预算分解（2026 年 LiveKit/Pipecat 生态共识）**

- 对话式语音 agent 的"人类感"门槛是感知延迟 <300ms（丝滑）、300-600ms（可接受但迟钝）、>600ms（用户开始不耐烦）、>1.5s（用户放弃）。**但 MeetingAI 的目标是"这句话说完几秒内建议出现"，预算比对话式 agent 宽松得多**，今天的流式级联技术水平（P50 729-947ms 首字延迟）本身已经远低于这个预算，说明当前 10-50s 端到端延迟的瓶颈不在"ASR 有多快"，而在触发机制和非流式整段生成。
- 关键提速手段（futureagi.com《Optimize LiveKit Latency 2026》归纳，2026-05 更新）：流式 ASR 首个 partial 就路由给 LLM（不等整句说完）、prefix/prompt 缓存（把固定的 system prompt/工具 schema 放在前缀命中缓存价）、投机式/预生成、短轮次用小模型、区域路由。叠加后可把 1.2-1.4s 的轮次压到 500-650ms p95。
- **语义 turn detection / 语义 VAD**：OpenAI 官方 `semantic_vad` 用语义分类器判断"用户是否说完"，而不是单纯等静音，能区分"嗯……"这种拖尾和"就这样"这种确定性收尾（OpenAI 官方文档）；Speechmatics 博客提出用小型指令微调 SLM 做语义 turn detector，比纯静音 VAD 更准，同时能降低 API 调用次数和成本。这个思路可以直接迁移到 MeetingAI 现有的"字数阈值+沉默阈值"触发器，升级为"语义事件触发"（话题切换、抛出问题、达成/未达成共识等），呼应 2026-05-23 报告已指出的缺口。
- **对 `AIEngine.swift` / `MeetingContextBuilder.swift` 最直接可落地的两点**：(1) 当前是非流式整段 HTTP 请求，改成 SSE 流式渲染可以立刻改善感知延迟，且不涉及模型或架构变更；(2) 智谱 GLM 系列已通过第三方计费页确认支持"缓存输入"（GLM-4.7 缓存输入 $0.11/M vs 正常输入 $0.60/M，约 5.5 倍折扣），说明只要把 system prompt / 固定说明部分做成稳定前缀，就能吃到缓存折扣，而当前 `MeetingContextBuilder` 每次都重新拼接完整 prompt 字符串，没有利用这个机制。

### 问题 3：本地/端侧组件（Apple Silicon，2026 年中）

**本地流式 ASR**

| 方案 | 性能实测 | 语言覆盖 | 备注 |
|---|---|---|---|
| whisper.cpp（Metal 加速） | M1 上 RTF~0.10（30s 音频 3s 处理），M4 Pro RTF~0.03（30s 音频 0.9s）；large-v3 RTF 0.45、WER~2.5% 但不适合实时 | 99 语言（含中文） | getspeakup.app 2026-01 基准测试 |
| Parakeet.cpp / MLX（NVIDIA Parakeet 系列，纯 C++/Metal） | Apple Silicon GPU 上 10s 音频编码器推理约 27ms（比 CPU 快 96 倍）；流式变体延迟可配置 80ms-1120ms | **主要面向英语**（V2 仅英语，V3 扩展到 25 语言），中文覆盖不确定 | modelslab.com 2026 基准；spokenly.app 对比 |
| Apple `SpeechAnalyzer`（WWDC25 新 API） | 官方称比 Whisper Large V3 Turbo 快约 2×，长音频/多人会议场景为设计目标，无速率上限，全本地 | 未在本次调研中找到中文识别质量的公开评测 | **要求 iOS/macOS 26+**；MeetingAI 当前 `macOS 14+` 部署目标，若要用需升最低版本或 `#available` 双路径 |

**本地小模型初筛（"值不值得说"的前置判断）**

行业里"小模型先分类/路由，大模型只在需要时接管"的模式已经比较成熟（Medium《Model Router》实践帖：本地小模型常驻，300ms 内完成分类；Berkeley RouteLLM 项目专门做"质量驱动的级联升级"）。但**本次调研没有找到把这个模式直接用于"会议实时值不值得插话"这个具体场景的案例**——这是一个合理的架构迁移思路，但属于推测性建议，未经业界验证，如果采用应该先做小规模 pilot（比如用一个便宜的分类调用或规则引擎过滤掉明显不该触发的时刻，减少打到 GLM-5.2 全文分析的次数），而不是直接当作既定最佳实践。MeetingAI 现有 prompt 已经让 GLM 自己输出 `should_speak`，这个前置过滤器要解决的是"减少无谓的全量调用"，不是替代现有判断逻辑。

### 问题 4：实时说话人分离

| 方案 | 是否真正流式 | 实测/声称延迟 | 备注 |
|---|---|---|---|
| pyannoteAI（商用托管服务，非开源 pyannote.audio） | 声称支持 | 官方营销页声称"150ms 以下实时" | 厂商自述，本次调研未找到第三方独立验证 |
| 开源 pyannote.audio 3.1 | **不是原生流式** | GPU 上约 5-10x 实时吞吐（即处理速度倍率，非低延迟流式接口），CPU 约等于实时 | 描述的是批处理/预录音频的处理速度，不是流式 API |
| NVIDIA NeMo Sortformer | 仅离线聚类 | — | 重叠语音检测上限 4 人 |
| **FluidAudio**（Swift SDK，MIT/Apache，GitHub `FluidInference/FluidAudio`） | **是，专为设备端流式设计** | M1（2022）实测 0.017 RTF（60 倍实时），在更便宜/低功耗硬件上比 pyannote 在 Nvidia V100 上的 0.025 RTF 快约 50% | 已被同品类竞品 **Hedy**（实时 AI 会议教练）以及 slipbox.ai、VoiceInk 生产使用；底层用 Parakeet ASR + Silero VAD + ANE 加速的流式说话人分离 |
| sherpa-onnx | 有 Swift 绑定但不适合本场景 | FluidAudio 团队明确因其不支持 ANE、只能 CPU 推理而放弃，"延迟和功耗都更高" | 直接反驳"随便找个 sherpa-onnx 就行"的想法 |

**结论**：FluidAudio 是本次调研里对 MeetingAI 最具体、最可执行的新发现——理论上可以把现在"分片封存→OSS 上传→Fun-ASR 非实时 HTTP→GLM 交叉纠错→merge→会中回填"的归档轨换成本地近实时轨，消除 OSS 依赖和分钟级延迟。**但中文场景的说话人分离准确率和 ASR 质量本次调研未验证**（找到的生产案例都偏英语场景），落地前必须先做一次真实中文会议录音的手工基准测试，再决定是替换还是与现有 Fun-ASR 轨并行。

### 问题 5：成本对比（8 小时/天持续旁听，2026-07-18 公开价格估算）

以下为基于官方定价页手工换算的**量级估算**，非厂商公布的固定单价，标注了推导方式和不确定性：

| 架构 | 依据 | 8 小时/天估算 | 30 天/月估算 |
|---|---|---|---|
| **当前级联基线**（DashScope `qwen3-asr-flash-realtime` 流式 ASR + 按需 GLM-5.2 分析） | ASR：0.00033 元/秒 × 28800 秒 ≈ ¥9.5（~$1.3）；LLM：假设一天触发约 100-150 次分析、每次 3k-8k tokens 上下文，GLM-5.2 约 $1.4/$4.4 每 M tokens | **约 $3-7/天** | **约 $100-200/月** |
| OpenAI `gpt-realtime-2.1` 全程常开 | 官方计价折算约 $0.23/min（典型通话），社区实测区间 $0.04-$0.30/min | $19-110/天（480 分钟） | **约 $580-3,300/月** |
| Gemini `3.1-flash-live-preview`（仅文字输出、几乎不要语音输出） | 输入 $0.005/min，输出成本可通过关闭语音输出大幅压低 | 约 $2.4-5/天 | **约 $70-150/月**（与级联基线同量级，但未验证中文/多人质量） |
| 智谱 `GLM-Realtime-Flash` 全程常开 | 官方价 0.18 元/分钟 | ¥86.4/天（~$12） | **约 ¥2,600/月（~$360）**，且 8K 上下文/约 2 分钟通话记忆对小时级会议不够用，需要外部拼接上下文，实际可用性存疑 |
| 阿里 `qwen3.5-omni-flash-realtime` | 官方按 token 计价（$3.71/M 音频输入），未找到官方"tokens/秒"换算比例，本估算按 Gemini 公开的 25 tokens/秒惯例类比换算 | 约 $2.7/天（**推测值，非官方数字**） | 约 $80/月（**推测值**） |
| 本地方案（FluidAudio/whisper.cpp 做 ASR+分离，仅偶尔调用云端大模型做洞察生成） | ASR/分离边际成本趋近于零（仅耗电），云端成本与现有级联基线的 LLM 部分相当 | **理论上最低**，但取决于中文准确率是否达标 | 同上 |

**结论**：8 小时/天持续旁听场景下，OpenAI Realtime 类的"按分钟计费的音频原生模型"成本比现有级联方案高 1-2 个数量级，不可行；Gemini Live 在"只要文字、不要语音回复"的配置下勉强能打到与现有方案同量级，值得做一次成本+质量的联合验证 spike；国产音频原生模型（Qwen-Omni-Realtime、GLM-Realtime）要么定价换算不确定（Qwen），要么上下文窗口明显不够小时级会议用（GLM）。**本地化（尤其是说话人分离）是唯一有希望把边际成本压到接近零的方向**，但技术验证（尤其是中文识别质量）尚未完成。

---

## 推荐方案

**推荐**：维持级联/混合架构（与 MeetingAI 现有设计一致），不整体切换到音频原生 S2S 模型；把这次调研的具体发现转化为四个优先级明确的改进方向，而不是重新设计架构。

**理由**：
1. 2026 年中的多篇一手证据（2 篇 arxiv 论文 + LiveKit/Modulate/Gradium 等厂商实测）一致认为生产级场景下级联仍是默认选择，S2S 只在"自然度即产品"时占优——MeetingAI 需要的是结构化文字卡片而非语音对话，天然更适合级联。
2. 商用音频原生 API 按"轮流对话"设计，与 MeetingAI"持续旁听多人、按需吐卡片"的场景结构性不匹配；退化到"仅转写"模式并不能消除级联，只是换了个更贵的 ASR 供应商。
3. 8 小时/天持续开启的成本模型下，多数音频原生方案比现有级联贵 1-2 个数量级；唯一成本量级相当的 Gemini Live（文字输出模式）尚未验证中文与多人质量，不能贸然替换主链路。
4. 本次调研找到的两个具体、可执行、成本可控的改进点（AIEngine 流式渲染 + prompt 缓存；FluidAudio 本地流式说话人分离）比"换整个 ASR/AI 架构"风险小得多，且能直接命中现有已知延迟瓶颈。

---

## 实施建议

### 关键步骤（建议按此顺序，逐个验证再推进，不要一次性全上）

1. **低风险、立即可做**：把 `AIEngine.swift` 的 HTTP 分析请求改为 SSE 流式渲染；把 `MeetingContextBuilder` 的固定说明/instructions 部分整理成稳定前缀，验证 OpenRouter/GLM 是否命中缓存折扣。预期：改善感知延迟，不改变架构和成本结构。
2. **中风险、需要 spike**：把现有"字数阈值+沉默阈值"触发器升级为语义事件触发（可以先用规则/小模型分类，而不是直接接商用语义 VAD API），验证是否能减少无效触发同时不漏掉真正值得说的时刻。
3. **需要中文数据验证**：用真实中文会议录音对 FluidAudio 做一次说话人分离 + ASR 的手工基准测试（对照现有 Fun-ASR 归档轨的准确率），决定是否用它替换或并行归档轨。这是本次调研里潜在收益最大但风险也最集中的一步，务必先内部验证再决定要不要动生产链路。
4. **可选、探索性**：单独做一个 Gemini 3.1 Flash Live "音频输入/文字输出"模式的技术 spike，验证能否在关闭语音输出、控制成本的前提下拿到比现有 DashScope 流式 ASR 更好的转写质量或更低延迟；如果验证通过，可以考虑作为 ASR 层的候选替换，但**不建议**用它取代现有 GLM-5.2 洞察生成层（S2S 的结构化输出/工具调用成熟度仍不如纯文本 LLM）。
5. **本地小模型初筛**：作为最后一步的可选优化，若步骤 2 的语义触发器效果验证有效，可以进一步探索用本地小模型或规则引擎做"值不值得触发 GLM-5.2"的前置过滤，减少全量分析调用次数——但这一步在业界没有直接先例，需要自行设计评估指标（比如"漏报关键盲点"的容忍度）。

### 风险点
- Apple `SpeechAnalyzer` 需要 macOS 26+，与项目当前 `macOS 14+` 部署目标冲突，若采用需要评估升级最低系统版本对现有用户/自用场景的影响。
- FluidAudio、Parakeet 系产品在公开资料里的生产案例集中在英语场景，中文准确率是本报告最大的未验证假设，不能凭 benchmark 数字直接下注。
- Qwen-Omni-Realtime 的成本估算依赖从 Gemini 公开的"25 tokens/秒"惯例做的类比换算，并非阿里官方确认的数字，如果真要评估该方案需要先找官方 SDK 实测或客服确认。
- 豆包（Doubao）端到端实时语音大模型本次调研未拿到官方明确的"元/分钟"计价（只找到相关 ASR/合成产品的价格），如后续需要对比该方案需要专项补充调研或直接查阅火山引擎控制台的价格计算器。

### 依赖项
- FluidAudio spike 依赖能拿到一段有说话人标注 ground truth 的中文会议录音做对照评测。
- Gemini Live spike 依赖 Google AI Studio/Vertex 的可用配额和 API key（当前项目密钥体系里没有 Gemini key，需要先申请）。

---

## 参考来源

- [Building Enterprise Realtime Voice Agents from Scratch (arXiv 2603.05413)](https://arxiv.org/pdf/2603.05413) — 支撑"原生 S2S 太慢、级联是行业标准、P50 947ms"
- [The Cascade Equivalence Hypothesis (arXiv 2602.17598)](https://arxiv.org/html/2602.17598v2) — 支撑"语音 LLM 隐式等价于 ASR→LLM 级联，噪声下级联更准"
- [LiveKit: Pipeline vs. Realtime — Which is the better Voice Agent Architecture?](https://livekit.com/blog/realtime-vs-cascade) — 支撑"级联工具调用更准，S2S 结构化输出边界情况仍在收敛"
- [Modulate.ai: Beat the Black Box](https://www.modulate.ai/ebooks/beat-the-black-box-why-cascade-beats-speech-to-speech-for-enterprise-voice-agents) — 支撑"流式级联 P50 947ms、可观测性优势"
- [Gradium: Cascaded Voice Agents vs Speech-to-Speech 2026](https://gradium.ai/content/cascaded-voice-agent-vs-speech-to-speech-2026) — 支撑"2026 年生产环境选择仍是级联"
- [LiveKit 2026 Playbook (Forasoft)](https://www.forasoft.com/blog/article/livekit-ai-agents-guide) — 支撑"默认级联，混合是 2026 模式"
- [OpenAI: Advancing voice intelligence with new models in the API](https://openai.com/index/advancing-voice-intelligence-with-new-models-in-the-api) / [Realtime API pricing 实测 (aireiter.com)](https://aireiter.com/blog/openai-realtime-api-pricing) — 支撑 gpt-realtime-2.1 定价
- [Gemini Live API 官方定价页](https://ai.google.dev/gemini-api/docs/pricing) / [Gemini Live API Best Practices](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/best-practices) — 支撑 Gemini 3.1 Flash Live 定价与流式最佳实践
- [Alibaba Cloud Model Studio 模型定价](https://www.alibabacloud.com/help/en/model-studio/model-pricing) / [阿里云百炼模型调用价格](https://help.aliyun.com/zh/model-studio/model-pricing) — 支撑 Qwen3.5-Omni-Realtime 及 qwen3-asr-flash-realtime 官方定价
- [GLM-Realtime 官方文档 (docs.bigmodel.cn)](https://docs.bigmodel.cn/cn/guide/models/sound-and-video/glm-realtime) — 支撑 GLM-Realtime 定价与 8K/2 分钟通话记忆限制
- [OpenAI Realtime VAD 官方文档（语义 VAD）](https://developers.openai.com/api/docs/guides/realtime-vad) — 支撑语义 VAD 机制
- [Speechmatics: How to build smarter turn detection for Voice AI](https://blog.speechmatics.com/semantic-turn-detection) — 支撑 SLM 语义 turn detector 优于纯静音 VAD
- [FutureAGI: Optimize LiveKit Voice Latency 2026](https://futureagi.com/blog/how-to-optimize-livekit-latency-2026) — 支撑延迟优化技术栈（流式 partial、prefix caching 等）
- [GitHub: FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) / [Near-Real-Time Speaker Diarization on CoreML (inference.plus)](https://inference.plus/p/low-latency-speaker-diarization-on) — 支撑本地流式说话人分离方案与实测 RTF 数据
- [pyannote.audio Guide 2026 (vexascribe.com)](https://vexascribe.com/pyannote-audio) / [Best Open-Source Speaker Diarization Models 2026 (neosophie.com)](https://neosophie.com/en/blog/20260223-diarization) — 支撑开源 diarization 现状（非原生流式）
- [Apple WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277) / [Apple's New Speech Framework 对比](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer) — 支撑 SpeechAnalyzer 能力与 macOS 26+ 限制
- [whisper.cpp Benchmark: Speed & Accuracy on Apple Silicon (getspeakup.app)](https://getspeakup.app/blog/whisper-cpp-benchmark-mac) / [Parakeet.cpp vs Whisper 2026 (modelslab.com)](https://modelslab.com/blog/audio-generation/parakeet-cpp-vs-whisper-self-hosted-asr-comparison-2026) — 支撑本地 ASR 性能数据
- [Deepgram/AssemblyAI 2026 定价对比 (forasoft.com)](https://www.forasoft.com/blog/article/speaker-diarization-api-comparison) / [AssemblyAI: Best APIs for real-time speech recognition 2026](https://www.assemblyai.com/blog/best-api-models-for-real-time-speech-recognition-and-transcription) — 支撑云端流式 ASR/diarization 价格与延迟基准
- [AWS: Live Call Analytics and Agent Assist](https://aws.amazon.com/blogs/machine-learning/live-call-analytics-and-agent-assist-for-your-contact-center-with-amazon-language-ai-services) — 支撑 contact center 级联架构参考设计
- [Speechmatics: What is Ambient AI?](https://www.speechmatics.com/company/articles-and-news/what-is-ambient-ai-how-voice-first-tech-is-rewriting-the-rules-of-healthcare) — 支撑"被动旁听类产品仍用 ASR+LLM 级联"的旁证

---

## 不确定项 / 需要后续验证

1. 豆包（Doubao）端到端实时语音大模型的官方"元/分钟"定价本次未确认。
2. Qwen3.5-Omni-Realtime 的音频 tokens/秒换算比例是类比 Gemini 公开惯例推算的，非阿里官方数字。
3. Apple SpeechAnalyzer 与 FluidAudio（Parakeet 系）在中文场景下的转写/分离准确率均未验证，公开生产案例集中在英语场景。
4. pyannoteAI 商用服务"150ms 以下实时"的说法是厂商官网表述，未见第三方独立复现。
5. Gemini Live API 能否真正支持"多人、非轮流对话"的持续旁听模式（而非仅仅是禁用自动语音回复），官方文档未明确覆盖这个用例，需要实测验证。
