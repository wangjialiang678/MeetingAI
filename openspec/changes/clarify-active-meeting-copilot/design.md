## Context

MeetingAI already has the beginnings of a live assistant: transcript-triggered analysis, mode switching, and an insight feed. But the product intent is still split across old docs. Some materials describe a periodic summarizer; others describe an active meeting partner that can question assumptions, verify facts, and run background research. The result is implementation drift and no clear contract for future work.

The critical constraint is user attention. This app runs during a live conversation, so the assistant has to be useful without becoming another participant users must manage.

## Goals / Non-Goals

**Goals:**
- Define the assistant as a proactive but low-noise meeting copilot.
- Separate "the assistant evaluates context" from "the assistant is allowed to speak."
- Introduce a visible background research queue with clear lifecycle states.
- Bound prompt growth over long meetings while preserving useful context.
- Make externally verified information distinguishable from raw model speculation.
- Give future implementation work a clean product contract across UI, ViewModel, and AI integration.

**Non-Goals:**
- Implement the full research stack in this documentation change.
- Lock the product to a specific search provider or model vendor.
- Redesign the entire desktop layout beyond what is necessary to support feed + queue behavior.
- Solve historical meeting storage, multi-user sync, or cross-platform support.

## Decisions

### 1. Treat the assistant as a feed-first copilot, not a chat-first bot

The primary interaction model is a time-ordered assistant feed. User chat remains available, but it is secondary. This matches the real usage pattern during meetings: the user mostly glances, occasionally pins, and only sometimes types.

Alternatives considered:
- Keep pure chat semantics: rejected because it implies turn-taking and overweights explicit prompting.
- Use modal notifications: rejected because they steal attention at the wrong moment.

### 2. Separate evaluation cadence from speaking budget

The assistant may inspect the evolving meeting state more frequently than it actually posts visible output. That lets the system stay context-aware while still enforcing silence when nothing important has changed.

Alternatives considered:
- Fixed periodic speaking: rejected because it creates low-value filler.
- Fully unconstrained event-driven output: rejected because it risks feed spam.

### 3. Expand the card taxonomy to make intent legible

The current insight/reply/summary split is too coarse for the target product. The clarified design needs explicit proactive suggestion, fact-check, and research-result states so users can quickly judge whether a card is speculation, interaction, or externally informed output.

Alternatives considered:
- Hide all card types and use one generic card: rejected because trust and scanning suffer.
- Over-categorize cards with many labels: rejected because it adds visual noise.

### 4. Model research as visible background work

Once the assistant can investigate topics beyond the local transcript, that work needs a queue model with task ownership, progress, and result handoff. Otherwise research feels magical when it works and confusing when it stalls.

Alternatives considered:
- Inline all research as immediate replies: rejected because slow work has no visible state.
- Keep research invisible until complete: rejected because users cannot tell whether the assistant is doing anything.

### 5. Preserve user control with lightweight actions

The default controls should be low-friction: accept, dismiss, pin, ask. The assistant must tolerate being ignored. We explicitly do not require heavy feedback loops such as rating every card.

Alternatives considered:
- Thumbs up/down on every card: rejected because the interaction cost is too high during meetings.
- Mandatory confirmation before every proactive card: rejected because it kills spontaneity.

### 6. Use layered memory instead of replaying the whole meeting

Long meetings cannot keep sending the full transcript plus every prior assistant reply. The context model should separate:

- hot window: the last few minutes of raw transcript, kept almost verbatim
- active window: the recent discussion block, summarized lightly but still detailed
- durable memory: earlier discussion compressed into structured notes such as decisions, open questions, and unresolved tensions

This mirrors how a strong human listener behaves: earlier context remains available, but current interpretation is dominated by the live thread of discussion.

Alternatives considered:
- Full-transcript replay every time: rejected because latency and cost grow monotonically and attention relevance drops.
- Aggressive truncation to only the last few minutes: rejected because important earlier commitments and decisions would be lost.

### 7. Treat the product as single-operator by default

For the current private boardroom scenario, assistant output is assumed to be visible only to the local operator. That simplifies privacy posture and avoids inventing collaboration requirements the app does not yet have.

Alternatives considered:
- Design for shared participant visibility now: rejected because it adds permission and presentation questions before the core product is proven.

## Risks / Trade-offs

- [Too much activity] → Enforce per-mode speaking budgets and silence rules before adding richer behaviors.
- [Low trust in AI claims] → Distinguish speculative suggestions from verified outputs and require source-backed framing for research results.
- [Prompt bloat in long sessions] → Compact older context into structured memory after each analysis or topic boundary.
- [Research latency] → Separate quick verification from deep research so short checks do not clog the queue.
- [Implementation complexity] → Stage work through model changes, decision engine refactor, then external research integration.
- [UI clutter] → Keep the queue secondary to the main feed and avoid notification-like affordances.

## Migration Plan

1. Update the shared product contract in OpenSpec, using this change as the forward-looking requirement set.
2. Refactor feed and model types to support expanded card kinds, rolling memory state, and research task state.
3. Split current trigger logic into evaluation, speaking budget, context compaction, and research-task creation.
4. Add research execution, persisted research documents, and source-backed result rendering.
5. Align entry-point docs such as README and supporting design notes to point back to OpenSpec as the canonical source.

## Open Questions

- Should quick fact checks run automatically in advisor mode, or always require user confirmation?
- How much source detail should appear inline on result cards versus behind an expand action?
- Should research tasks survive meeting end, or remain session-scoped only?
- Do mode changes affect only output frequency, or also the kinds of interventions the assistant may make?
