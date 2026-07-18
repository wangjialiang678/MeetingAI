# Diarization Storage Decision

Date: 2026-05-23

## Current Status

MeetingAI now records local WAV chunks, uploads configured chunks to OSS, submits Fun-ASR HTTP tasks, polls for `transcription_url`, merges sentence-level `speaker_id` results, and backfills `.diarized.jsonl`, `.transcript.md`, `.events.log`, and the transcript UI.

The remaining blocker is operational configuration: the app needs an OSS bucket and credentials available through env/vault. The app must not hard-code storage credentials or leak temporary upload secrets into logs.

## Decision

For the personal prototype, use the fastest direct OSS path:

- Private Alibaba Cloud OSS bucket.
- Official `alibabacloud-oss-swift-sdk-v2`.
- App uploads local single-channel WAV chunks to `objectPrefix/session/chunk.wav`.
- App generates short-lived GET presigned URLs and passes those HTTPS URLs to DashScope Fun-ASR.
- Local and cloud chunks are retained by default.

The presigned URL service option remains a future hardening path if this prototype becomes multi-user or needs stricter secret isolation.

## Current Config

- `diarization.provider`
- `diarization.uploadStorage`
- `diarization.uploadRegion`
- `diarization.uploadEndpoint`
- `diarization.uploadBucket`
- `diarization.objectPrefix`
- `diarization.presignTTLSeconds`
- `diarization.funASRBaseURL`
- `diarization.pollIntervalSeconds`
- `diarization.pollTimeoutSeconds`
- `diarization.speakerCount`

Environment overrides:

- `MEETINGAI_DIARIZATION_PROVIDER`
- `MEETINGAI_DIARIZATION_UPLOAD_STORAGE`
- `MEETINGAI_DIARIZATION_UPLOAD_REGION`
- `MEETINGAI_DIARIZATION_UPLOAD_ENDPOINT`
- `MEETINGAI_DIARIZATION_UPLOAD_BUCKET`
- `MEETINGAI_DIARIZATION_OBJECT_PREFIX`
- `MEETINGAI_DIARIZATION_PRESIGN_TTL_SECONDS`
- `MEETINGAI_DIARIZATION_FUNASR_BASE_URL`
- `MEETINGAI_DIARIZATION_POLL_INTERVAL_SECONDS`
- `MEETINGAI_DIARIZATION_POLL_TIMEOUT_SECONDS`
- `MEETINGAI_DIARIZATION_SPEAKER_COUNT`

Secret values are loaded from process env or `~/.claude/api-vault.env`:

- `DASHSCOPE_API_KEY`
- `OSS_ACCESS_KEY_ID`
- `OSS_ACCESS_KEY_SECRET`
- `OSS_SESSION_TOKEN` (optional STS token)

Do not add access keys, secret keys, signed URLs, or API key values to `config.json`, `.events.log`, `.chunks.jsonl`, or committed docs.

## Enablement Checklist

- [x] Select OSS as the first prototype storage boundary.
- [x] Define credential loading through process env / `~/.claude/api-vault.env`, not committed config.
- [x] Add uploader implementation behind `DiarizationAudioUploader`.
- [x] Add provider task polling with bounded retries and event logging.
- [x] Persist completed/failed provider lifecycle records in `.events.log`.
- [x] Redact signed URL query values from event and chunk logs.
- [ ] Configure a real OSS bucket and run one real Fun-ASR HTTP file-transcription task with `diarization_enabled=true`.
