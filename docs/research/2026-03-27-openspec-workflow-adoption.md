# OpenSpec Workflow Adoption for MeetingAI

## Question

How should this repository adopt OpenSpec without discarding the existing product and architecture docs?

## Sources Reviewed

- Local OpenSpec repo: `README.md`, `docs/getting-started.md`, `docs/workflows.md`, `docs/cli.md`
- OpenSpec implementation: `src/core/init.ts`, `src/core/command-generation/adapters/codex.ts`, `schemas/spec-driven/*`
- Current project docs:
  - `docs/specs/prd.md`
  - `docs/specs/architecture.md`
  - `docs/design/2026-03-06-active-research-assistant.md`
  - `docs/design/2026-03-06-scenarios-active-ai.md`
  - `docs/design/2026-03-06-tech-architecture.md`
  - `README.md`
  - `AGENTS.md`

## Key Findings

1. OpenSpec should be added beside the current docs, not used to replace them in one shot.
2. `openspec/specs/` should hold the current agreed system behavior, while `openspec/changes/<name>/` should hold the new clarification work.
3. `openspec init --tools codex --profile core --force` is the safest non-interactive initialization path for this repo.
4. OpenSpec's Codex command adapter writes slash-command prompts to the global Codex home and project skills to `.codex/skills/`; it does not delete the root `AGENTS.md`.
5. Existing project docs have drift and should not be treated as one canonical source:
   - `README.md` still references `~/.claude/api-vault.env`
   - older docs still describe `audio-asr-go` and port `18080`
   - project `AGENTS.md` describes the newer `asr-bridge` + `18089` setup
6. The best migration path is:
   - initialize OpenSpec
   - create baseline specs from the current implemented and intended behavior
   - create one change focused on clarifying the future "active meeting copilot" direction

## Recommended Baseline Capability Split

- `meeting-session`: recording lifecycle, transcript capture, session persistence
- `asr-bridge-integration`: local ASR subprocess management and transcript streaming
- `ai-meeting-assistant`: auto analysis, manual prompting, AI response behavior
- `app-configuration`: config loading, API key expectations, runtime prerequisites

This split keeps current behavior readable and gives the new change room to evolve assistant behavior without rewriting everything.

## Recommended First Change

Create a change dedicated to clarifying the next product direction around "meeting-time AI suggestions", rather than mixing it with old MVP docs.

Suggested change scope:

- redefine assistant behavior from passive summarizer toward proactive copilot
- clarify when AI may interrupt, when it should stay quiet, and what kinds of suggestions are allowed
- define research / verification / insight cards as explicit user-facing behaviors
- define constraints for latency, noise, trust, and user control

Suggested change name:

- `clarify-active-meeting-copilot`

## Practical Notes

- Keep existing `docs/` files as supporting references for now.
- Use OpenSpec as the new source of truth going forward.
- After baseline specs exist, future product changes should happen through `openspec/changes/*` instead of directly editing the old PRD first.
