## Purpose

This spec defines the assistant behavior that turns live meeting transcript into structured AI insights, replies, and summaries in the right-side feed.

## Requirements

### Requirement: Assistant operating modes
The system SHALL let the user switch the assistant between multiple intervention levels during a meeting.

#### Scenario: User changes assistant mode
- **GIVEN** a meeting session is active
- **WHEN** the user selects a different assistant mode from the mode control
- **THEN** the system applies the corresponding speaking cadence and trigger thresholds to subsequent analysis

### Requirement: Analysis triggers
The system SHALL trigger AI analysis from both explicit user action and transcript-driven heuristics.

#### Scenario: Manual analysis request
- **GIVEN** a meeting session is active
- **WHEN** the user clicks the immediate analysis control
- **THEN** the system requests a new AI analysis for the current meeting context unless analysis is already in progress

#### Scenario: Transcript accumulation triggers analysis
- **GIVEN** a meeting session is active
- **AND** transcript content has grown beyond the configured threshold for the current mode
- **WHEN** new transcript text arrives
- **THEN** the system triggers AI analysis automatically

#### Scenario: Silence or ceiling trigger runs analysis
- **GIVEN** a meeting session is active
- **AND** unanalysed transcript content exists
- **WHEN** the silence timer or maximum wait interval threshold is exceeded for the current mode
- **THEN** the system triggers AI analysis automatically

### Requirement: Insight feed output types
The system SHALL present AI output as typed cards in the insight feed.

#### Scenario: Insight card is appended
- **GIVEN** AI analysis returns content that should be surfaced proactively
- **WHEN** the response kind is an insight
- **THEN** the system appends an insight card to the feed with timestamped content

#### Scenario: Summary card is appended
- **GIVEN** the assistant generates a stage summary
- **WHEN** the response kind is a summary
- **THEN** the system appends a summary card styled distinctly from regular insights

#### Scenario: Direct user question receives a reply card
- **GIVEN** the user submits a question from the input field
- **WHEN** the assistant returns a reply
- **THEN** the system appends a reply card that preserves the originating user question

### Requirement: Analysis context construction
The system SHALL construct AI context from prior assistant output and tiered meeting transcript history.

#### Scenario: AI request includes recent and earlier transcript context
- **GIVEN** transcript history exists for the meeting
- **WHEN** the system prepares an AI request
- **THEN** it includes the latest assistant output when available
- **AND** labels transcript content so recent discussion is prioritized over earlier context

### Requirement: Assistant output control
The system SHALL avoid flooding the meeting feed with redundant assistant output.

#### Scenario: Assistant remains silent when nothing new is worth saying
- **GIVEN** AI analysis determines there is no meaningful new output
- **WHEN** the structured response says not to speak
- **THEN** the system suppresses a new card for that analysis round

#### Scenario: Important cards can be preserved
- **GIVEN** the feed contains AI output cards
- **WHEN** the user pins a card
- **THEN** the system keeps it marked as important for later review and export
