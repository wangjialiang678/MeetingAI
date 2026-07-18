## Purpose

This spec defines the user-visible meeting session lifecycle: starting a meeting, capturing transcript and audio, importing prior context, and saving outputs when the session ends.

## Requirements

### Requirement: Meeting session lifecycle
The system SHALL allow the user to start one active meeting session and stop it explicitly from the main window.

#### Scenario: Start a meeting session
- **GIVEN** the app is open and no meeting is running
- **WHEN** the user clicks the start meeting control
- **THEN** the system starts the ASR stack and microphone recording for a new session
- **AND** the UI enters a recording state with visible duration

#### Scenario: Stop a meeting session
- **GIVEN** a meeting session is running
- **WHEN** the user clicks the end meeting control
- **THEN** the system stops recording, disconnects the ASR client, and terminates the local ASR subprocess
- **AND** the session state returns to idle

### Requirement: Live transcript display
The system SHALL render transcript entries in chronological order during a meeting session.

#### Scenario: Partial transcript appears
- **GIVEN** the ASR client emits an in-progress transcript fragment
- **WHEN** the fragment is received
- **THEN** the transcript panel shows it as provisional content

#### Scenario: Final transcript replaces provisional content
- **GIVEN** the latest transcript entry is provisional
- **WHEN** the ASR client emits a final transcript for the same utterance
- **THEN** the system replaces the provisional entry with a final entry
- **AND** the transcript panel keeps the conversation order intact

### Requirement: Session artifact persistence
The system SHALL persist meeting artifacts to local application storage when transcript and insight data are available.

#### Scenario: Final transcript is appended to session file
- **GIVEN** a session file has been created for the current meeting
- **WHEN** a final transcript entry is received
- **THEN** the system appends a timestamped line to the session transcript file

#### Scenario: Session outputs are available after meeting end
- **GIVEN** a meeting session has produced transcript, audio, or AI insight data
- **WHEN** the meeting ends
- **THEN** the system preserves the generated transcript, recording, and AI log files in the sessions directory

### Requirement: Historical transcript import
The system SHALL allow users to import a prior transcript file into the active meeting context.

#### Scenario: Import valid transcript lines
- **GIVEN** a meeting session is active
- **WHEN** the user selects a valid transcript text file from the import flow
- **THEN** the system prepends parsed transcript lines into the in-memory transcript list
- **AND** imported entries are treated as earlier context for later analysis
