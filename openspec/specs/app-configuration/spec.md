## Purpose

This spec defines how the app loads runtime configuration, secrets, and user-defined prompt customization.

## Requirements

### Requirement: Local runtime configuration
The system SHALL load app runtime settings from local configuration sources with sensible defaults.

#### Scenario: JSON config overrides defaults
- **GIVEN** a valid app config file exists in Application Support
- **WHEN** the app loads configuration
- **THEN** values from that file override built-in defaults for ASR and AI settings

#### Scenario: Missing config falls back to defaults
- **GIVEN** no app config file is present
- **WHEN** the app loads configuration
- **THEN** the system continues using built-in defaults for ASR and AI settings

### Requirement: Local secret loading
The system SHALL read required API credentials from a local environment file before network-backed features run.

#### Scenario: Secret values are loaded from vault file
- **GIVEN** a supported local vault file contains API key entries
- **WHEN** the app loads configuration
- **THEN** the system makes those credentials available to the ASR bridge and AI client

### Requirement: Custom analysis prompt override
The system SHALL let the user override the default analysis system prompt from settings.

#### Scenario: Empty custom prompt uses default behavior
- **GIVEN** the custom prompt field is empty
- **WHEN** analysis is triggered
- **THEN** the system uses the built-in default prompt for the selected assistant mode

#### Scenario: Non-empty custom prompt overrides default behavior
- **GIVEN** the user has saved a custom prompt in settings
- **WHEN** analysis is triggered
- **THEN** the system uses the saved prompt instead of the default analysis prompt
