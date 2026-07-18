STATUS: APPROVED（用户指令：“对比实时转写和说话人分离转写，用大模型纠正明显识别错误（置信度高）”）

# 转写修正稿（TranscriptRefiner）实施计划

## 需求理解
- 两份转写来自不同引擎（实时 qwen3-asr / 非实时 Fun-ASR），错误互不相关 → 交叉验证有效
- “替代实时转写”实现为：修正稿成为主产物（.refined.md），实时转写保留为过程数据（守则：机器后处理不覆盖实时事实）
- 保守纠错：仅高置信度的同音字/专有名词/数字；不润色、不增删信息；输出修正清单供审计

## 步骤
- [ ] S1 Sources/TranscriptRefiner.swift：系统提示词 + 用户内容构建（A=实时 B=说话人分离，字符预算截断）+ JSON 解析（复用 AIEngine.extractStructuredJSONText）+ .refined.md 渲染
- [ ] S2 AIEngine 暴露 rawCompletion(HTTP)；MeetingViewModel 触发：会议停止后全部分片 settle（完成或失败）→ 一次性 refine，事件 transcript_refine_started/refined/refine_failed
- [ ] S3 tests/transcript_refiner_smoke.swift（RED→GREEN）：提示词内容、解析成败、渲染格式、截断标记；接入 run-p0-p1（P0-19 + P1-35）
- [ ] S4 swift build + P0/P1；P2 待当前会议结束后补跑；文档同步（CLAUDE.md 产物清单 + dev-log）

## 风险
- LLM 幻觉性“纠错”：靠保守提示词 + corrected 标记 + 修正清单审计；后续可加相似度阈值硬校验
- 会议停止后异步 refine 与新会议开始的竞态：复用 DiarizationSessionGate generation 守卫
- 长会 token：GLM 5.2 1M ctx，v1 设 12 万字符预算截断并标注
