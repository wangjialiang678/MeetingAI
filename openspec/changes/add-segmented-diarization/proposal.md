## Why

MeetingAI now has enough live ASR and session logging to support real meeting tests, but it still cannot tell who spoke after the meeting. Users need diarized meeting transcripts for review, while the current realtime Qwen-ASR path does not support speaker separation and `.txt` can remain empty when ASR only emits partial results.

## What Changes

- Add a segmented recording pipeline that can seal local audio chunks during an active meeting without blocking realtime ASR.
- Add diarization backfill behavior that accepts asynchronous file-transcription results with speaker IDs and merges them into the session timeline.
- Persist chunk lifecycle and diarized transcript artifacts so real tests can be audited even when uploads or model tasks fail.
- Keep realtime ASR as the low-latency UI and AI-trigger path; diarization is a delayed archival backfill path.
- Defer the concrete upload storage provider until it is explicitly chosen.

## Capabilities

### New Capabilities

- `segmented-diarization`: Defines local audio chunking, diarization task lifecycle, speaker-labeled transcript merge, and session artifacts for post-meeting speaker separation.

### Modified Capabilities

- `meeting-session`: Session output requirements expand from transcript/recording/AI logs to include chunk lifecycle and diarized transcript artifacts when the segmented diarization feature is enabled.

## Impact

- `AudioRecorder` or a new recorder-side component must expose sealed single-channel audio chunks.
- `MeetingViewModel` must track chunk lifecycle, diarization task state, and merge/backfill events.
- New models are needed for audio chunks, diarized sentence segments, and task state.
- Session files may include `{session}.chunks.jsonl` and `{session}.diarized.jsonl`.
- `.transcript.md` should be able to render both live partial/final transcript and backfilled speaker-labeled transcript.
- Tests must cover chunk lifecycle and fake diarization merge without requiring a real upload provider.
