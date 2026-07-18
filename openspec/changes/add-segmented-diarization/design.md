## Context

The current app streams microphone audio to `asr-bridge` for realtime Qwen-ASR and writes full-session recording files. Real smoke tests show the realtime path emits partial transcript while recording is active, but final transcript may be absent for short or continuous speech. The `.transcript.md` snapshot therefore acts as the current review fallback.

Speaker separation is a different workload. DashScope documentation indicates the realtime Qwen-ASR models do not support diarization, while Fun-ASR non-realtime file transcription supports `diarization_enabled` and `speaker_count` for single-channel files. That makes speaker separation an archival backfill path, not a replacement for the realtime UI path.

## Goals / Non-Goals

**Goals:**

- Seal local single-channel audio chunks during a meeting while realtime ASR continues to run.
- Persist chunk lifecycle records for audit and retry.
- Merge diarized sentence results into a stable session timeline using chunk time offsets.
- Produce reviewable speaker-labeled artifacts without requiring realtime speaker labels.
- Provide a fake/local diarization path for deterministic tests before selecting upload storage.

**Non-Goals:**

- Choose or implement OSS, presigned URL, or another upload storage provider in this change.
- Display perfect realtime speaker labels during the meeting.
- Replace current realtime ASR or AI trigger behavior.
- Guarantee cross-chunk speaker identity beyond the IDs returned by the diarization provider.

## Decisions

### Decision: Use a dual-track ASR architecture

Realtime Qwen-ASR remains responsible for low-latency partial/final transcript, UI updates, and AI triggers. Segmented Fun-ASR file transcription is added as a delayed backfill path for speaker labels.

Alternative considered: switch all recognition to non-realtime file transcription. That would simplify diarization but would remove live meeting assistance, which is the product's core interaction.

### Decision: Use single-channel WAV chunks as the MVP recording unit

Chunks should be sealed as single-channel WAV files. This matches Fun-ASR diarization constraints, avoids the MP3 encoder availability issue observed in real smoke tests, and keeps local fixture tests deterministic.

Alternative considered: MP3 chunks. MP3 is smaller, but macOS `AVAudioFile` MP3 creation failed in the current environment and would add avoidable risk before real testing.

### Decision: Persist chunk lifecycle separately from transcript content

The app should write `{session}.chunks.jsonl` for chunk state and `{session}.diarized.jsonl` for speaker-labeled sentence output. This keeps upload/task failures auditable without corrupting live transcript content.

Alternative considered: write diarized sentences directly into `.transcript.md`. That is useful for review output but not enough for debugging retries, offsets, and provider errors.

### Decision: Merge by chunk offset and overlap-aware de-duplication

Each diarized result carries chunk-local timestamps. The merger converts them to session-relative timestamps by adding the chunk start offset, then sorts and removes duplicate overlap-region sentences.

Alternative considered: append results in task completion order. That breaks when chunks complete out of order and makes review output unstable.

### Decision: Upload provider remains an explicit open decision

The code should allow a future uploader implementation, but this change should not hard-code cloud storage. The first implementation can use fake/local diarization fixtures to validate lifecycle and merge behavior.

Alternative considered: immediately integrate Aliyun OSS. That is a real architecture and privacy decision and should be confirmed before code commits to it.

## Risks / Trade-offs

- Provider speaker IDs may not remain stable across chunks -> Preserve provider IDs and expose low-confidence continuity instead of pretending identities are confirmed.
- Chunk overlap can duplicate sentences -> Keep 3-5 seconds overlap and merge by time/text similarity.
- Upload or diarization can fail mid-meeting -> Mark individual chunks failed and keep realtime transcript unaffected.
- Diarization backfill may arrive after the user closes the app -> Persist task state and resume/retry only after explicit implementation of background execution.
- WAV chunks are larger than compressed audio -> Accept for MVP reliability; revisit compression after upload and diarization are stable.

## Migration Plan

1. Add local data models and deterministic merge tests.
2. Add a local chunk lifecycle recorder with fake chunk creation in tests.
3. Add session artifact writers for `.chunks.jsonl` and `.diarized.jsonl`.
4. Update `.transcript.md` rendering to include speaker-labeled backfill when available.
5. Add the real uploader and Fun-ASR task client only after the storage provider is chosen.

Rollback is straightforward for the MVP: disable segmented diarization and keep the realtime ASR and existing session artifacts unchanged.

## Open Questions

- Which storage provider should host temporary chunk files for DashScope `file_urls`?
- Should chunks be deleted immediately after successful diarization, after meeting end, or by retention policy?
- Should users manually enter expected `speaker_count`, or should the first version use automatic speaker count?
- How should the UI represent “speaker labels are being backfilled” without distracting from the live meeting?
