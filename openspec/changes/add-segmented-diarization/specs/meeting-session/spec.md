## MODIFIED Requirements

### Requirement: Session artifact persistence
The system SHALL persist meeting artifacts to local application storage when transcript, insight, recording, chunk, or diarization data are available.

#### Scenario: Final transcript is appended to session file
- **GIVEN** a session file has been created for the current meeting
- **WHEN** a final transcript entry is received
- **THEN** the system appends a timestamped line to the session transcript file

#### Scenario: Session outputs are available after meeting end
- **GIVEN** a meeting session has produced transcript, audio, AI insight, chunk, or diarization data
- **WHEN** the meeting ends
- **THEN** the system preserves the generated transcript, recording, AI log, event log, and any segmented diarization artifacts in the sessions directory

#### Scenario: Partial-only transcript is reviewable
- **GIVEN** a meeting session has produced provisional transcript but no final transcript entries
- **WHEN** the meeting ends
- **THEN** the system preserves a readable transcript snapshot containing the provisional content
