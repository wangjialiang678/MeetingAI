# MeetingAI Closed-Loop Test Plan

## Scope

This plan covers the current MeetingAI direction: local ASR startup, app launch stability, layered AI context construction, session artifact completeness, and the basic operator-facing meeting workflow. It includes automatic macOS GUI validation when Accessibility permissions are enabled for `System Events`, but it does **not** yet claim full microphone-to-analysis end-to-end automation.

## Strategy

- P0/P1 is headless by default: builds, pure Swift smokes, shell syntax checks, and static integration checks only.
- Default GUI coverage is centralized in one P2 fixture workflow to avoid repeatedly launching and switching the native UI for small changes.
- Fine-grained scripts such as `tests/app_launch_smoke.sh`, `tests/gui_smoke.sh`, and `tests/meeting_toggle_smoke.sh` are retained for targeted debugging, but they are not part of the default P0/P1 batch.
- The default GUI batch now validates the main operator path in one app session: launch window, open settings, start meeting, receive fixture transcript, trigger analysis, surface backend status, stop meeting, and verify session artifacts (`.txt`, `.mp3`, `.ai.md`, `.events.log`, `.transcript.md`).

## P0: Automatic Survival Checks

Any P0 failure blocks delivery.

| # | Test | Command | Pass Criteria |
|---|------|---------|---------------|
| P0-1 | Go ASR bridge build | `cd asr-bridge && go build -o bin/asr-bridge .` | exit code = 0 |
| P0-2 | Swift app build | `swift build` | exit code = 0 |
| P0-3 | Audio recorder drain gate smoke | `swiftc Sources/AudioRecorder.swift tests/audio_recorder_drain_gate_smoke.swift -o .build/audio_recorder_drain_gate_smoke && ./.build/audio_recorder_drain_gate_smoke` | stop waits for in-flight tap callback before releasing recorder resources |
| P0-4 | Layered context smoke | `swiftc Sources/Models.swift Sources/MeetingContextBuilder.swift tests/context_builder_smoke.swift -o .build/context_builder_smoke && ./.build/context_builder_smoke` | exit code = 0 |
| P0-5 | AI response parsing smoke | `swiftc Sources/Models.swift Sources/AIEngine.swift tests/ai_response_parsing_smoke.swift -o .build/ai_response_parsing_smoke && ./.build/ai_response_parsing_smoke` | standard `message.content`, NVIDIA `message.reasoning_content`, and array text content parse |
| P0-6 | Diarization merge smoke | `swiftc Sources/Models.swift Sources/DiarizationModels.swift tests/diarization_merge_smoke.swift -o .build/diarization_merge_smoke && ./.build/diarization_merge_smoke` | chunk-local timestamps, out-of-order results, overlap de-duplication, and boundary-touching non-deduplication pass |
| P0-7 | Diarization chunk lifecycle smoke | `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationChunker.swift tests/diarization_chunk_lifecycle_smoke.swift -o .build/diarization_chunk_lifecycle_smoke && ./.build/diarization_chunk_lifecycle_smoke` | PCM16 data seals to single-channel WAV chunks and writes created/waiting lifecycle JSONL |
| P0-8 | Diarization backfill smoke | `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationBackfillWriter.swift tests/diarization_backfill_smoke.swift -o .build/diarization_backfill_smoke && ./.build/diarization_backfill_smoke` | speaker segments persist to `.diarized.jsonl`, append a speaker backfill section to `.transcript.md`, and write a safe lifecycle event |
| P0-9 | Diarization provider boundary smoke | `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift tests/diarization_provider_boundary_smoke.swift -o .build/diarization_provider_boundary_smoke && ./.build/diarization_provider_boundary_smoke` | uploader/task request types and credential-free provider config placeholders behave as expected |
| P0-10 | Fun-ASR provider smoke | `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationFunASRProvider.swift tests/fun_asr_provider_smoke.swift -o .build/fun_asr_provider_smoke && ./.build/fun_asr_provider_smoke` | submit request, task polling response, `transcription_url`, sentence `speaker_id`, and signed URL redaction parse correctly |
| P0-11 | Diarization pipeline smoke | `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationBackfillWriter.swift Sources/DiarizationFunASRProvider.swift Sources/DiarizationPipeline.swift tests/diarization_pipeline_smoke.swift -o .build/diarization_pipeline_smoke && ./.build/diarization_pipeline_smoke` | fake uploader/provider runs upload -> submit -> complete -> merge -> backfill and redacts signed URL query values |
| P0-12 | OSS support smoke | `swiftc Sources/DiarizationModels.swift Sources/DiarizationOSSSupport.swift tests/diarization_oss_support_smoke.swift -o .build/diarization_oss_support_smoke && ./.build/diarization_oss_support_smoke` | OSS endpoint normalization, readiness checks, and deterministic object keys avoid local path leakage |
| P0-13 | Transcript Markdown writer smoke | `swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/TranscriptMarkdownWriter.swift tests/transcript_markdown_writer_smoke.swift -o .build/transcript_markdown_writer_smoke && ./.build/transcript_markdown_writer_smoke` | later snapshots preserve existing speaker backfill, and fresh speaker segments replace stale backfill |
| P0-14 | Diarization session gate smoke | `swiftc Sources/DiarizationSessionGate.swift tests/diarization_session_gate_smoke.swift -o .build/diarization_session_gate_smoke && ./.build/diarization_session_gate_smoke` | a new meeting session rejects stale diarization callback tokens |
| P0-15 | Real Fun-ASR smoke outcome helper | `bash tests/real_meeting_smoke_fun_asr_outcome.sh` | real smoke only reports Fun-ASR completed after every finalized chunk completes, and failure wins over partial success |
## P1: Automatic Code and Integration Checks

These checks validate the critical integration points without requiring live microphone or UI interaction.

| # | Test | Check | Pass Criteria |
|---|------|-------|---------------|
| P1-1 | asr-bridge does not expose refine route | `! grep -q 'refine' asr-bridge/main.go` | no match |
| P1-2 | asr-bridge does not expose transcribe-sync route | `! grep -q 'transcribe-sync' asr-bridge/main.go` | no match |
| P1-3 | ASR env path uses api-vault | `grep -q 'api-vault.env' asr-bridge/env.go` | match |
| P1-4 | Go module path is correct | `grep -q 'meetingai/asr-bridge' asr-bridge/go.mod` | match |
| P1-5 | Server manager targets asr-bridge | `grep -q 'asr-bridge' Sources/ASRServerManager.swift` | match |
| P1-6 | Health endpoint is `/health` | `grep -q '/health' Sources/ASRServerManager.swift` | match |
| P1-7 | ASR client uses `/v1/stream` | `grep -q '/v1/stream' Sources/ASRClient.swift` | match |
| P1-8 | ASR audio payload is base64-encoded | `grep -q 'base64EncodedString' Sources/ASRClient.swift` | match |
| P1-9 | Default ASR port is 18089 | `grep -q '18089' Sources/Config.swift` | match |
| P1-10 | Layered context builder is wired into ViewModel | `grep -q 'MeetingContextBuilder.buildSnapshot' Sources/MeetingViewModel.swift` | match |
| P1-10b | Analysis backend can be overridden by smoke environment | `grep -q 'MEETINGAI_ANALYSIS_BACKEND' Sources/MeetingViewModel.swift` | match |
| P1-10c | Recording falls back to WAV when MP3 is unavailable | `grep -q 'WAV recording fallback enabled' Sources/AudioRecorder.swift` | match |
| P1-11 | App launch smoke script exists and is executable | `test -x tests/app_launch_smoke.sh` | exit code = 0 |
| P1-12 | UI accessibility precheck script exists and is executable | `test -x tests/ui_accessibility_precheck.sh` | exit code = 0 |
| P1-13 | GUI smoke script exists and is executable | `test -x tests/gui_smoke.sh` | exit code = 0 |
| P1-14 | Meeting toggle smoke script exists and is executable | `test -x tests/meeting_toggle_smoke.sh` | exit code = 0 |
| P1-15 | Fixture meeting E2E script exists and is executable | `test -x tests/fixture_meeting_e2e.sh` | exit code = 0 |
| P1-16 | P2 batch script exists and is executable | `test -x tests/run-p2-ui.sh` | exit code = 0 |
| P1-17 | ASR reconnect policy smoke | `bash tests/asr_reconnect_policy_smoke.sh` | reconnect dedupe, backoff, give-up, and backoff cap checks pass |
| P1-18 | Real rehearsal script syntax | `test -x scripts/run-real-meeting-rehearsal.sh && bash -n scripts/run-real-meeting-rehearsal.sh` | script is executable and parses |
| P1-19 | Full batch script syntax | `test -x tests/run-all.sh && bash -n tests/run-all.sh` | script is executable and parses |
| P1-20 | Real meeting smoke script syntax | `test -x scripts/run-real-meeting-smoke.sh && bash -n scripts/run-real-meeting-smoke.sh` | script is executable and parses |
| P1-21 | Diarization chunker is wired into meeting flow | `grep -q 'DiarizationAudioChunker' Sources/MeetingViewModel.swift` | match |
| P1-22 | Diarization provider config placeholders exist | `grep -q 'diarizationUploadStorage' Sources/Config.swift` | match |
| P1-23 | Fun-ASR provider is wired into meeting flow | `grep -q 'DashScopeFunASRProvider' Sources/MeetingViewModel.swift` | match |
| P1-24 | OSS uploader dependency is wired | `grep -q 'alibabacloud-oss-swift-sdk-v2' Package.swift && grep -q 'DiarizationOSSUploader' Sources/MeetingViewModel.swift` | match |
| P1-25 | Speaker backfill UI is wired | `grep -q 'speakerBackfillSegments' Sources/TranscriptView.swift` | match |

## P1.5: Layered Context Behavior Smoke

These cases are covered by `tests/context_builder_smoke.swift`.

| # | Behavior | Pass Criteria |
|---|----------|---------------|
| P1.5-1 | Recent discussion is prioritized over early transcript | smoke test passes |
| P1.5-2 | Durable memory uses pinned cards and summaries first | smoke test passes |
| P1.5-3 | Previous AI output is clamped before reuse | smoke test passes |

## P2: GUI / Workflow Validation

These are the next closed-loop targets. They become fully automatic only when macOS Accessibility permissions are enabled.

### P2-A: Automatic when Accessibility is enabled

- [x] Launch the app and confirm the main window is present.
- [x] Verify the top bar renders the meeting title and top-level controls.
- [x] Click the settings gear and confirm a settings sheet appears.
- [x] Start a meeting from the UI and confirm the recording state changes visibly.
- [x] Trigger manual analysis from the UI and confirm the feed updates.
- [x] Confirm backend status is visible in the insight pane and persisted to `.ai.md`.
- [x] Click manual analysis twice and confirm the second click surfaces rate-limit feedback.
- [x] Drive a fixture-backed meeting flow end to end, including transcript, analysis, and session artifacts.
- [x] Confirm every fixture session writes `.events.log` with meeting lifecycle/config/transcript events.
- [x] Confirm every fixture session writes `.transcript.md` with readable final/partial status markers.

### P2-B: Manual fallback while Accessibility is blocked

- [ ] Launch App -> main window appears
- [ ] Click `开始会议` -> recording state appears in the top bar
- [ ] Speak into the microphone -> transcript panel shows entries
- [ ] Click `立即分析` -> right-side feed appends a new card or a no-new-content system response
- [ ] End meeting -> transcript, mp3, AI log, event log, and transcript Markdown files appear in the sessions directory
- [ ] Kill `asr-bridge` during a meeting -> reconnect flow appears, duplicate reconnects are suppressed, backoff increases, and the app gives up clearly after max attempts
- [x] Run `scripts/run-real-meeting-smoke.sh 90` for a short live microphone + online ASR/HTTP AI smoke. Exit code 0 is PASS; exit code 2 is environment BLOCKED and must be recorded with `docs/runtime-logs/{RUN_ID}`. The script forces a short diarization chunk duration and requires multiple chunk WAVs. Latest PASS: `docs/runtime-logs/real-smoke-2026-05-23-18-09-29`
- [ ] Run `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1 MEETINGAI_DIARIZATION_UPLOAD_BUCKET=<bucket> scripts/run-real-meeting-smoke.sh 90 75` after OSS bucket credentials are present. This variant additionally requires OSS upload, every finalized chunk to complete Fun-ASR polling, `.diarized.jsonl`, speaker markdown backfill, and signed URL redaction.
- [ ] Run `scripts/run-real-meeting-rehearsal.sh` for a 20-30 minute microphone + online model rehearsal and archive `docs/runtime-logs/{RUN_ID}` plus the latest session files

### P2-C: Next diarization validation target

- [x] Add deterministic local chunk lifecycle smoke without real microphone input.
- [x] Wire rotating local chunks into the real meeting audio path without blocking realtime ASR sends.
- [x] Merge fake/provider diarization sentence results with chunk time offsets and overlap de-duplication.
- [x] Persist `{session}.chunks.jsonl` with created and waiting-for-upload lifecycle events.
- [x] Persist completed/failed provider lifecycle events after fake/real provider tasks exist.
- [x] Persist merged fake/provider diarization result into `{session}.diarized.jsonl`.
- [x] Render speaker labels in `.transcript.md` after diarization backfill.
- [x] Add a fake/local provider orchestration test that runs chunk result -> merge -> backfill end to end.
- [x] Record safe diarization backfill lifecycle events in `.events.log`.
- [ ] Run one real Fun-ASR HTTP file-transcription task with `diarization_enabled=true` once OSS bucket configuration is available in the environment/config.
- [x] Define provider-neutral upload/task request types and credential-free config placeholders.
- [x] Document the storage decision required before real Fun-ASR upload/task polling.

## Closed-Loop Status Rules

- **PASS**: P0 passes, P1 passes, and any GUI automation blockers are explicitly reported rather than silently ignored.
- **BLOCKED**: P0/P1 pass, but GUI automation is not available because macOS Accessibility permissions are disabled.
- **FAIL**: Any P0 or P1 code check fails.

## Execution Command

- Full automatic baseline, including one GUI fixture pass: `bash tests/run-all.sh`
- Headless P0/P1 only, preferred after small backend/local changes: `bash tests/run-p0-p1.sh`
- Centralized GUI workflow batch: `bash tests/run-p2-ui.sh`
- Short real backend smoke: `scripts/run-real-meeting-smoke.sh 90`
- Short real backend + Fun-ASR diarization smoke: `MEETINGAI_REQUIRE_FUNASR_DIARIZATION=1 MEETINGAI_DIARIZATION_UPLOAD_BUCKET=<bucket> scripts/run-real-meeting-smoke.sh 90 75`
- Long real rehearsal log collector: `scripts/run-real-meeting-rehearsal.sh`
- Targeted GUI smoke (debug only): `bash tests/gui_smoke.sh`
- Targeted meeting toggle (debug only): `bash tests/meeting_toggle_smoke.sh`
- Legacy full closed-loop batch: `bash tests/run-p0-p1.sh && bash tests/run-p2-ui.sh`
