## 1. Data Model and Merge Core

- [x] 1.1 Add models for audio chunks, chunk lifecycle state, diarization tasks, and speaker-labeled sentence records
- [x] 1.2 Implement a pure merge utility that converts chunk-local timestamps into session-relative diarized sentences
- [x] 1.3 Add overlap de-duplication for neighboring chunk results
- [x] 1.4 Add Swift smoke tests for normal merge, out-of-order task completion, and overlap de-duplication

## 2. Local Chunk Lifecycle

- [x] 2.1 Add an `AudioSegmenter` or recorder-side component that can seal single-channel WAV chunks without blocking realtime ASR
- [x] 2.2 Persist `{session}.chunks.jsonl` lifecycle records for created and waiting-for-upload chunks
- [x] 2.2b Persist completed and provider-failed lifecycle records once fake/real diarization providers exist
- [x] 2.3 Add deterministic fixture tests for chunk creation and lifecycle logging without real microphone input

## 3. Diarization Backfill

- [x] 3.1 Add a fake/local diarization provider result path for tests that returns speaker-labeled sentence fixtures
- [x] 3.2 Persist `{session}.diarized.jsonl` from merged fake/provider output
- [x] 3.3 Update `.transcript.md` rendering to include speaker labels when diarized records exist
- [x] 3.4 Record diarization lifecycle events in `.events.log`

## 4. Real Provider Boundary

- [x] 4.1 Define the uploader protocol and provider-neutral request/response types
- [x] 4.2 Add configuration placeholders for provider selection without hard-coding storage credentials
- [x] 4.3 Document the storage decision required before enabling real Fun-ASR upload and task polling
- [x] 4.4 Add OSS upload + GET presigned URL implementation using the official Alibaba Cloud OSS Swift SDK
- [x] 4.5 Add DashScope Fun-ASR submit/poll/result parser with `diarization_enabled=true`
- [x] 4.6 Wire sealed chunks into background upload -> provider task -> merge -> backfill flow

## 5. Validation and Documentation

- [x] 5.1 Add the new local smoke tests to `tests/run-p0-p1.sh`
- [x] 5.2 Update `docs/test-plan.md` with chunk lifecycle, fake diarization validation, OSS support, Fun-ASR parsing, and pipeline validation
- [x] 5.3 Update `docs/dev-log.md` after each completed implementation slice
- [x] 5.4 Run `bash tests/run-all.sh` for this slice; real short smoke remains required before or after recorder-side chunking changes
- [x] 5.5 Add review regressions for Markdown backfill preservation, stale-session callback gating, Fun-ASR `UNKNOWN`, OSS V4 redaction, and all-chunk smoke completion
