# Analysis Backend Benchmark

## Question

For MeetingAI's meeting-time analysis, should we keep using the current HTTP model, switch to Codex CLI, or use a hybrid split?

## Sources Reviewed

- Local benchmark report: `docs/research/2026-03-27-analysis-backend-benchmark.json`
- Current implementation:
  - `Sources/AIEngine.swift`
  - `Sources/Config.swift`
  - `~/.codex/config.toml`
- Official OpenAI Help Center:
  - [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan/)
  - [Codex CLI and Sign in with ChatGPT](https://help.openai.com/en/articles/11381614)

## Environment

- Date: 2026-03-27
- Codex login status: `Logged in using ChatGPT`
- Local Codex config:
  - `model = "gpt-5.4"`
  - `model_reasoning_effort = "xhigh"`
- HTTP backend under test:
  - model: `qwen/qwen3.5-122b-a10b`
  - endpoint: `https://integrate.api.nvidia.com/v1/chat/completions`

## Test Cases

1. `summary_case`
   - Ask for a concise structured stage summary from a short meeting excerpt.
2. `insight_case`
   - Ask for one high-value meeting intervention focused on blind spots and decision variables.

Both backends were asked to return the same JSON shape:

```json
{
  "should_speak": true,
  "content": "内容",
  "kind": "insight|summary|reply",
  "topic_keywords": ["关键词"]
}
```

## Results

| Case | HTTP | Codex CLI | Notes |
|------|------|-----------|-------|
| `summary_case` | 20.955s | 26.420s | HTTP slightly faster |
| `insight_case` | 48.663s | 18.963s | Codex CLI much faster in this sample |

## Quality Notes

### 1. Summary quality

- HTTP summary:
  - good factual coverage
  - slightly more "reporting" tone
  - acceptable for passive summary cards
- Codex CLI summary:
  - slightly better structure
  - cleaner separation between "meeting mechanism" and "AI assistant boundary"
  - still not dramatically better than HTTP

Conclusion:
- Summary is not a strong enough reason by itself to pay Codex latency/cost.
- HTTP is sufficient for stage summaries.

### 2. Insight quality

- HTTP insight:
  - good
  - more prescriptive
  - proposed a concrete mechanism (`诊断轮`)
  - slightly longer and more "solution-forward"
- Codex CLI insight:
  - more compressed
  - sharper on the hidden decision variable
  - better matches the desired "strong旁听顾问" style
  - more suitable for meeting-time intervention cards

Conclusion:
- For high-value insight generation, Codex CLI is the stronger fit.
- In this sample it was also faster than the HTTP path, though this should not be assumed as a universal rule yet.

## Product Decision

Use **Hybrid** as the default strategy:

- `HTTP`
  - stage summaries
  - quick follow-up replies
  - lower-stakes analysis
- `Codex CLI`
  - deep insight cards
  - high-value structural interventions
  - "strong observer/advisor" moments

## Important Caveats

1. This benchmark is small-sample, not statistically stable.
2. Codex CLI is still a local agent runtime, not a lightweight pure inference API.
3. Official OpenAI docs say Codex usage under ChatGPT plans is limited by plan quotas, and if a user previously used API-key login they may need `codex logout` then re-login to switch to subscription-based access.
4. On this machine specifically, local Codex is configured to use `gpt-5.4`, and `codex exec -m gpt-5.4` succeeds, so treating Codex CLI as a GPT-5.4-backed local analysis backend is valid in practice for this environment.

## Recommended Implementation

Expose three modes in settings:

- `HTTP`
- `Codex CLI`
- `Hybrid`

Hybrid routing rule:

- `insight` → `Codex CLI`
- `summary` → `HTTP`
- `reply` → `HTTP`

Fallback rule:

- If Codex CLI fails, automatically fall back to HTTP and log the failure.
