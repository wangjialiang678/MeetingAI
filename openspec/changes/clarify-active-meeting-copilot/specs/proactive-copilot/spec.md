## ADDED Requirements

### Requirement: Proactive intervention policy
The system SHALL allow the assistant to proactively contribute only when it can add clear value to the meeting.

#### Scenario: Assistant challenges unexamined consensus
- **GIVEN** the meeting discussion is converging on a decision
- **AND** the assistant detects an unaddressed risk, hidden assumption, or missing perspective
- **WHEN** the value threshold for speaking is met
- **THEN** the system surfaces a concise proactive card that challenges or reframes the discussion

#### Scenario: Assistant stays quiet during low-value transcript
- **GIVEN** the meeting transcript consists mainly of small talk, repetition, or procedural chatter
- **WHEN** the assistant evaluates whether to speak
- **THEN** the system keeps the assistant silent

### Requirement: User control over proactive cards
The system SHALL let the user react to proactive cards with lightweight controls.

#### Scenario: User accepts a research suggestion
- **GIVEN** a proactive card includes a suggested research follow-up
- **WHEN** the user explicitly accepts that suggestion
- **THEN** the system creates a background research task for it

#### Scenario: User dismisses a proactive suggestion
- **GIVEN** a proactive suggestion card is visible
- **WHEN** the user dismisses or skips it
- **THEN** the system keeps the meeting flow moving without forcing a response

#### Scenario: User pins a high-value card
- **GIVEN** the assistant feed contains a useful proactive card
- **WHEN** the user pins it
- **THEN** the system preserves that card as an important takeaway for later review

### Requirement: Trustworthy factual posture
The system SHALL distinguish speculative suggestions from verified findings.

#### Scenario: Unverified claim is framed as a question
- **GIVEN** the assistant notices a potentially important factual claim that has not been checked
- **WHEN** it cannot verify that claim yet
- **THEN** the system phrases the output as an open question or research suggestion rather than as a confirmed fact

#### Scenario: Verified claim includes source-backed framing
- **GIVEN** the assistant has completed a fact check or research lookup
- **WHEN** it presents the result
- **THEN** the output makes it clear that the result comes from an external verification step
