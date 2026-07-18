## Why

Current project documents mix two different products: a passive meeting summarizer and a more active meeting copilot. That ambiguity is already causing drift across code, PRD, and design notes. We need one explicit target behavior for how AI should speak, when it should stay quiet, and how background research should feed back into the meeting without becoming noise.

## What Changes

- Define the target assistant as a proactive meeting copilot, not only a periodic summarizer.
- Add explicit behavior for AI-generated questions, challenge prompts, quick fact checks, and research suggestions.
- Add a background research queue so accepted research tasks have a visible lifecycle and results can flow back into the meeting feed.
- Define a layered meeting context model so the assistant weights recent discussion most heavily while compressing older material into structured memory.
- Tighten assistant requirements around interruption budget, user control, trust, and source-backed results.
- Make OpenSpec the primary source of truth for the product direction going forward.

## Capabilities

### New Capabilities
- `proactive-copilot`: Defines when the assistant may proactively surface challenges, questions, fact checks, and suggestions during a live meeting.
- `background-research-queue`: Defines how research tasks are created, shown, executed, and returned into the meeting flow.

### Modified Capabilities
- `ai-insight-assistant`: Expands the current assistant behavior from generic insight cards into a clearer low-noise card system with stronger speaking controls.

## Impact

- Product behavior and UX contracts in the right-side assistant panel
- Prompt construction, memory compaction, and transcript summarization strategy
- `MeetingViewModel` trigger logic, feed state, and output throttling
- `Models.swift` card and task models
- `InsightFeedView.swift` rendering and controls
- `AIEngine.swift` structured response contract
- Future web research / fact verification integration
- Project documentation entry points such as README and design docs
