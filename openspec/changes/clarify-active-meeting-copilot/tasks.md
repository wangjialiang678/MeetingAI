## 1. Shared Product Contract

- [ ] 1.1 Expand shared model types to represent proactive cards, fact-checks, research results, and research task states
- [x] 1.2 Update project entry-point docs to point readers at OpenSpec as the source of truth for assistant behavior

## 2. Assistant Decision Engine

- [ ] 2.1 Refactor `MeetingViewModel` so "evaluate context" is separate from "post a visible assistant card"
- [ ] 2.2 Implement explicit mode-based speaking budgets and silence/backoff rules
- [x] 2.3 Implement layered meeting memory with hot window, active window, and compressed durable summary
- [ ] 2.4 Extend the structured AI response contract to support the clarified card taxonomy

## 3. Background Research Workflow

- [ ] 3.1 Add creation paths for research tasks from both user requests and assistant suggestions
- [ ] 3.2 Implement in-memory research task lifecycle management with queued, running, completed, failed, and cancelled states
- [ ] 3.3 Persist completed research tasks as source-backed documents in a dedicated local directory
- [ ] 3.4 Integrate quick verification versus deep research execution paths with source-aware result formatting

## 4. Feed and Queue Experience

- [ ] 4.1 Update the right-side feed UI to render proactive cards, fact-check cards, reply cards, summary cards, and research result cards
- [ ] 4.2 Add a visible research queue section with lightweight accept, dismiss, cancel, and inspect interactions
- [ ] 4.3 Update saved AI meeting logs so pinned cards, research tasks, and source-backed results remain reviewable after the meeting
