## ADDED Requirements

### Requirement: Local audio chunk lifecycle
The system SHALL seal single-channel audio chunks during an active meeting when segmented diarization is enabled.

#### Scenario: Chunk is created during recording
- **GIVEN** a meeting session is recording
- **AND** segmented diarization is enabled
- **WHEN** the configured chunk duration elapses
- **THEN** the system seals a local audio chunk with a session-relative start time and end time
- **AND** records the chunk lifecycle in the session chunk log

#### Scenario: Chunk creation does not block realtime ASR
- **GIVEN** a meeting session is recording
- **AND** the system is sealing a chunk
- **WHEN** microphone audio continues to arrive
- **THEN** the system continues forwarding realtime audio to the active ASR connection

### Requirement: Diarization task lifecycle
The system SHALL track diarization task state for each sealed audio chunk.

#### Scenario: Chunk waits for upload provider
- **GIVEN** a chunk has been sealed
- **AND** no upload provider is configured
- **WHEN** the diarization pipeline evaluates the chunk
- **THEN** the chunk remains in a waiting state
- **AND** the session event log records that upload configuration is required

#### Scenario: Chunk task completes
- **GIVEN** a chunk has an associated diarization task
- **WHEN** the task returns sentence-level speaker labels
- **THEN** the system records the task as completed
- **AND** persists the raw chunk result reference and normalized diarized sentence records

#### Scenario: Chunk task fails
- **GIVEN** a chunk has an associated diarization task
- **WHEN** upload or transcription fails
- **THEN** the system records the chunk as failed with a diagnostic error
- **AND** realtime transcript and AI analysis remain available

### Requirement: Speaker-labeled transcript merge
The system SHALL merge diarized chunk results into a session-relative speaker transcript.

#### Scenario: Merge diarized sentence timestamps
- **GIVEN** a chunk starts at a known session-relative offset
- **WHEN** the provider returns a sentence with chunk-local begin and end timestamps
- **THEN** the system stores the sentence with session-relative begin and end timestamps
- **AND** preserves the provider speaker identifier

#### Scenario: De-duplicate overlap region
- **GIVEN** two neighboring chunks contain overlapping diarized sentences
- **WHEN** the system merges their results
- **THEN** duplicate overlap-region sentences are not shown twice in the speaker transcript

### Requirement: Diarization session artifacts
The system SHALL persist diarization artifacts separately from realtime transcript artifacts.

#### Scenario: Chunk lifecycle artifact is written
- **GIVEN** segmented diarization has created or evaluated chunks
- **WHEN** the session artifacts are saved
- **THEN** the system writes a `{session}.chunks.jsonl` artifact with chunk lifecycle records

#### Scenario: Diarized transcript artifact is written
- **GIVEN** at least one diarized sentence has been merged
- **WHEN** the session artifacts are saved
- **THEN** the system writes a `{session}.diarized.jsonl` artifact with speaker-labeled sentence records

#### Scenario: Markdown transcript includes speaker backfill
- **GIVEN** diarized sentence records are available
- **WHEN** the system writes `.transcript.md`
- **THEN** the transcript includes speaker labels alongside the readable meeting text
