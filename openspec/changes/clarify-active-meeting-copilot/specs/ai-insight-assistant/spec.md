## MODIFIED Requirements

### Requirement: Assistant operating modes
The system SHALL define assistant modes as product-level behavior presets that control both how often the assistant evaluates the meeting and how aggressively it may interrupt.

#### Scenario: Observer mode suppresses proactive output
- **GIVEN** the assistant is set to observer mode
- **WHEN** transcript content changes during the meeting
- **THEN** the system may continue collecting context
- **BUT** it SHALL NOT append proactive cards unless the user explicitly asks a question or requests analysis

#### Scenario: Advisor mode uses a low-noise speaking budget
- **GIVEN** the assistant is set to advisor mode
- **WHEN** the system evaluates whether to speak
- **THEN** it SHALL prefer sparse, high-signal output over continuous commentary

#### Scenario: Researcher mode allows denser interaction
- **GIVEN** the assistant is set to researcher mode
- **WHEN** the system detects worthwhile insights or research opportunities
- **THEN** it MAY surface them with a shorter interval than advisor mode

### Requirement: Analysis triggers
The system SHALL evaluate whether the assistant should speak based on explicit user action, transcript heuristics, and discussion-state signals.

#### Scenario: Manual analysis request always evaluates current context
- **GIVEN** a meeting session is active
- **WHEN** the user clicks the immediate analysis control
- **THEN** the system evaluates the current meeting context immediately unless analysis is already in progress

#### Scenario: New discussion signal triggers evaluation
- **GIVEN** a meeting session is active
- **AND** the transcript indicates substantial new content, a topic shift, or a stalled debate
- **WHEN** the trigger condition is reached for the current assistant mode
- **THEN** the system evaluates whether the assistant should speak

#### Scenario: Evaluation does not always produce a visible card
- **GIVEN** the system has triggered an assistant evaluation
- **WHEN** the result is judged low value or redundant
- **THEN** the system records no new visible assistant card for that round

### Requirement: Recency-weighted context construction
The system SHALL build assistant context with stronger weight on recent discussion than on early-meeting transcript.

#### Scenario: Recent transcript is prioritized over early transcript
- **GIVEN** a meeting has been running long enough to accumulate substantial transcript history
- **WHEN** the system prepares context for a new assistant evaluation
- **THEN** it includes the most recent discussion in higher detail than earlier portions of the meeting
- **AND** older material is represented primarily as compressed background memory rather than replayed verbatim

#### Scenario: Repeated periodic feedback does not cause unbounded prompt growth
- **GIVEN** the assistant has already produced multiple feedback rounds during the same meeting
- **WHEN** another evaluation is triggered later in the meeting
- **THEN** the system SHALL NOT resend the full meeting transcript and all prior assistant output unchanged
- **AND** instead uses a compact summary of earlier discussion plus detailed recent context

#### Scenario: Current discussion window dominates assistant output
- **GIVEN** the meeting topic has shifted in the last several minutes
- **WHEN** the assistant generates a new proactive response
- **THEN** the response focuses primarily on the active discussion window
- **AND** uses earlier meeting context only as supporting background

### Requirement: Insight feed output types
The system SHALL surface assistant output as low-noise cards with explicit semantic types.

#### Scenario: Proactive suggestion card appears
- **GIVEN** the assistant has identified a worthwhile challenge, question, or next-step suggestion
- **WHEN** it chooses to speak proactively
- **THEN** the system appends a proactive card in the assistant feed

#### Scenario: Fact-check card appears
- **GIVEN** the assistant has verified or clarified a factual claim discussed in the meeting
- **WHEN** a verification result is ready
- **THEN** the system appends a fact-check card that distinguishes verified findings from open questions

#### Scenario: Research result card appears
- **GIVEN** a background research task completes
- **WHEN** the result is delivered back into the meeting
- **THEN** the system appends a research result card linked to the originating task

#### Scenario: Direct user question still produces a reply card
- **GIVEN** the user submits a question from the input field
- **WHEN** the assistant returns an answer
- **THEN** the system appends a reply card that preserves the original question context

### Requirement: Assistant output control
The system SHALL protect user attention with explicit silence and delivery rules.

#### Scenario: Assistant never steals focus
- **GIVEN** the meeting is in progress
- **WHEN** the assistant appends a new proactive card
- **THEN** the system SHALL add it to the feed without modal interruption, audio, or focus-stealing UI

#### Scenario: Ignored suggestions do not trigger repeated nagging
- **GIVEN** the assistant has already surfaced a suggestion and the user does not interact with it
- **WHEN** no materially stronger evidence appears
- **THEN** the system SHALL avoid repeating the same suggestion aggressively

### Requirement: Single-operator visibility
The system SHALL treat assistant output as private to the local operator by default.

#### Scenario: Assistant cards are shown only in the local app session
- **GIVEN** the assistant produces proactive output during a meeting
- **WHEN** the card is rendered
- **THEN** it is shown only in the operator's local app session
- **AND** the system does not assume any shared participant-facing surface
