## Purpose

This spec defines how the app manages the local ASR bridge process and streams meeting audio into real-time transcript events.

## Requirements

### Requirement: Local ASR bridge startup
The system SHALL manage a local ASR bridge subprocess for live transcription.

#### Scenario: Build bridge binary on first use
- **GIVEN** the configured ASR bridge binary does not exist locally
- **WHEN** a meeting session starts
- **THEN** the system builds the bridge from the bundled Go project before launching it

#### Scenario: Confirm bridge health before use
- **GIVEN** the bridge process has been launched
- **WHEN** the startup flow polls the health endpoint
- **THEN** the system marks the bridge as running only after the health check succeeds

### Requirement: Audio streaming to ASR
The system SHALL stream microphone audio to the ASR client while recording is active.

#### Scenario: Recorded audio is forwarded to ASR
- **GIVEN** a meeting session is recording
- **WHEN** the audio recorder emits a new audio chunk
- **THEN** the system forwards the chunk to the active ASR connection

### Requirement: ASR error recovery
The system SHALL attempt limited reconnection when the ASR connection drops during an active meeting.

#### Scenario: Connection drop triggers reconnect
- **GIVEN** a meeting session is active
- **AND** the ASR connection fails with a connection-related error
- **WHEN** the failure is detected
- **THEN** the system informs the user that reconnection is in progress
- **AND** retries connecting the ASR client up to the configured maximum retry count

#### Scenario: Reconnect succeeds
- **GIVEN** an ASR reconnect attempt is in progress
- **WHEN** the client reconnects successfully
- **THEN** the system resumes transcript handling for the active meeting
- **AND** notifies the user that ASR is available again

### Requirement: Startup failure handling
The system SHALL surface startup errors when the bridge cannot be built or launched.

#### Scenario: Bridge startup fails
- **GIVEN** a meeting session is being started
- **WHEN** the bridge build, launch, or health check fails
- **THEN** the system prevents the meeting from entering a recording state
- **AND** shows a user-visible error explaining the failure
