## ADDED Requirements

### Requirement: Research task creation
The system SHALL support creating background research tasks from both assistant suggestions and direct user requests.

#### Scenario: Assistant suggestion becomes a task
- **GIVEN** the assistant has surfaced a research-worthy suggestion
- **WHEN** the user chooses to proceed
- **THEN** the system creates a new background research task tied to that meeting context

#### Scenario: User asks for research directly
- **GIVEN** a meeting session is active
- **WHEN** the user explicitly asks the assistant to look something up or investigate a topic
- **THEN** the system creates a background research task instead of treating the request as a simple inline reply

### Requirement: Research task lifecycle visibility
The system SHALL expose the current state of background research tasks in the meeting UI.

#### Scenario: Queue shows task progression
- **GIVEN** one or more research tasks exist for the active meeting
- **WHEN** their execution state changes
- **THEN** the system reflects queued, running, completed, failed, or cancelled status in the research queue

#### Scenario: User can cancel an unfinished task
- **GIVEN** a background research task has not completed yet
- **WHEN** the user cancels it
- **THEN** the system marks the task as cancelled and stops presenting it as active work

### Requirement: Research results return to the meeting feed
The system SHALL send completed research results back into the main assistant feed.

#### Scenario: Completed task produces a research result card
- **GIVEN** a background research task completes successfully
- **WHEN** the result is ready
- **THEN** the system appends a research result card to the main feed
- **AND** links that result to the originating research task

#### Scenario: Failed task reports failure without blocking the meeting
- **GIVEN** a background research task fails or times out
- **WHEN** the failure is detected
- **THEN** the system surfaces a non-blocking failure state for that task
- **AND** leaves the rest of the meeting session usable

### Requirement: Research artifact persistence
The system SHALL persist research outputs with source information for later review.

#### Scenario: Completed research task writes a document with sources
- **GIVEN** a background research task completes successfully
- **WHEN** the system finalizes that task
- **THEN** it writes a research document to the configured local research directory
- **AND** that document includes the task summary and the full set of collected source references

#### Scenario: Feed shows a concise summary while document holds the details
- **GIVEN** a research document has been written for a completed task
- **WHEN** the assistant reports the result back into the meeting feed
- **THEN** the visible card contains only a concise summary and why it matters now
- **AND** the detailed source material remains in the persisted research document

### Requirement: Research depth distinction
The system SHALL distinguish quick verification from deeper research.

#### Scenario: Quick verification bypasses long-running queue behavior
- **GIVEN** a user or assistant request is a narrow factual verification
- **WHEN** the system classifies it as a quick verification
- **THEN** it may return a fast fact-check result without presenting it as a long-running deep research task

#### Scenario: Broader investigation uses the queue
- **GIVEN** a request requires comparison, synthesis, or multiple-source lookup
- **WHEN** the system classifies it as deeper research
- **THEN** it represents that work as a visible queued task
