#!/bin/bash
# P0+P1 自动化闭环测试脚本
set -e
cd "$(dirname "$0")/.."

echo "=== P0: Build Tests ==="

echo "[P0-1] Go asr-bridge build..."
(cd asr-bridge && go build -o bin/asr-bridge .) && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-2] Swift build..."
swift build 2>&1 && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-3] Audio recorder drain gate smoke tests..."
swiftc Sources/AudioRecorder.swift tests/audio_recorder_drain_gate_smoke.swift -o .build/audio_recorder_drain_gate_smoke \
  && ./.build/audio_recorder_drain_gate_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-4] Context builder smoke tests..."
swiftc Sources/Models.swift Sources/MeetingContextBuilder.swift tests/context_builder_smoke.swift -o .build/context_builder_smoke \
  && ./.build/context_builder_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-5] AI response parsing smoke tests..."
swiftc Sources/Models.swift Sources/AIEngine.swift tests/ai_response_parsing_smoke.swift -o .build/ai_response_parsing_smoke \
  && ./.build/ai_response_parsing_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-6] Diarization merge smoke tests..."
swiftc Sources/Models.swift Sources/DiarizationModels.swift tests/diarization_merge_smoke.swift -o .build/diarization_merge_smoke \
  && ./.build/diarization_merge_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-7] Diarization chunk lifecycle smoke tests..."
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationChunker.swift tests/diarization_chunk_lifecycle_smoke.swift -o .build/diarization_chunk_lifecycle_smoke \
  && ./.build/diarization_chunk_lifecycle_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-8] Diarization backfill smoke tests..."
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationBackfillWriter.swift tests/diarization_backfill_smoke.swift -o .build/diarization_backfill_smoke \
  && ./.build/diarization_backfill_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-9] Diarization provider boundary smoke tests..."
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift tests/diarization_provider_boundary_smoke.swift -o .build/diarization_provider_boundary_smoke \
  && ./.build/diarization_provider_boundary_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-10] Fun-ASR provider smoke tests..."
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationFunASRProvider.swift tests/fun_asr_provider_smoke.swift -o .build/fun_asr_provider_smoke \
  && ./.build/fun_asr_provider_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-11] Diarization pipeline smoke tests..."
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/DiarizationProviderBoundary.swift Sources/DiarizationBackfillWriter.swift Sources/DiarizationFunASRProvider.swift Sources/DiarizationPipeline.swift tests/diarization_pipeline_smoke.swift -o .build/diarization_pipeline_smoke \
  && ./.build/diarization_pipeline_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-12] Diarization OSS support smoke tests..."
swiftc Sources/DiarizationModels.swift Sources/DiarizationOSSSupport.swift tests/diarization_oss_support_smoke.swift -o .build/diarization_oss_support_smoke \
  && ./.build/diarization_oss_support_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-13] Transcript markdown writer smoke tests..."
swiftc Sources/Models.swift Sources/DiarizationModels.swift Sources/TranscriptMarkdownWriter.swift tests/transcript_markdown_writer_smoke.swift -o .build/transcript_markdown_writer_smoke \
  && ./.build/transcript_markdown_writer_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-14] Diarization session gate smoke tests..."
swiftc Sources/DiarizationSessionGate.swift tests/diarization_session_gate_smoke.swift -o .build/diarization_session_gate_smoke \
  && ./.build/diarization_session_gate_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-15] Real meeting Fun-ASR outcome smoke tests..."
bash tests/real_meeting_smoke_fun_asr_outcome.sh \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-16] Insight deduplicator smoke tests..."
swiftc Sources/InsightDeduplicator.swift tests/insight_deduplicator_smoke.swift -o .build/insight_deduplicator_smoke \
  && ./.build/insight_deduplicator_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-17] ASR stale bridge policy smoke tests..."
swiftc Sources/ASRBridgePortGuard.swift tests/asr_stale_bridge_policy_smoke.swift -o .build/asr_stale_bridge_policy_smoke \
  && ./.build/asr_stale_bridge_policy_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-18] Transcript store smoke tests..."
swiftc Sources/Models.swift Sources/TranscriptStore.swift tests/transcript_store_smoke.swift -o .build/transcript_store_smoke \
  && ./.build/transcript_store_smoke \
  && echo "PASS" || { echo "FAIL"; exit 1; }

echo ""
echo "=== P1: Code Correctness ==="
FAIL=0

check() {
  if eval "$2"; then
    echo "[PASS] $1"
  else
    echo "[FAIL] $1"
    FAIL=1
  fi
}

check "P1-1 no refine route"        "! grep -q 'refine' asr-bridge/main.go"
check "P1-2 no transcribe-sync"     "! grep -q 'transcribe-sync' asr-bridge/main.go"
check "P1-3 api-vault.env path"     "grep -q 'api-vault.env' asr-bridge/env.go"
check "P1-4 go.mod module name"     "grep -q 'meetingai/asr-bridge' asr-bridge/go.mod"
check "P1-5 ASRServerManager path"  "grep -q 'asr-bridge' Sources/ASRServerManager.swift"
check "P1-6 health endpoint"        "grep -q '/health' Sources/ASRServerManager.swift"
check "P1-7 /v1/stream endpoint"    "grep -q '/v1/stream' Sources/ASRClient.swift"
check "P1-8 base64 audio"           "grep -q 'base64EncodedString' Sources/ASRClient.swift"
check "P1-9 port 18089"             "grep -q '18089' Sources/Config.swift"
check "P1-10 context builder integrated" "grep -q 'MeetingContextBuilder.buildSnapshot' Sources/MeetingViewModel.swift"
check "P1-10b analysis backend env override" "grep -q 'MEETINGAI_ANALYSIS_BACKEND' Sources/MeetingViewModel.swift"
check "P1-10c recording WAV fallback" "grep -q 'WAV recording fallback enabled' Sources/AudioRecorder.swift"
check "P1-11 app launch smoke script" "test -x tests/app_launch_smoke.sh"
check "P1-12 UI accessibility precheck script" "test -x tests/ui_accessibility_precheck.sh"
check "P1-13 GUI smoke script" "test -x tests/gui_smoke.sh"
check "P1-14 meeting toggle smoke script" "test -x tests/meeting_toggle_smoke.sh"
check "P1-15 fixture meeting e2e script" "test -x tests/fixture_meeting_e2e.sh"
check "P1-16 P2 batch script" "test -x tests/run-p2-ui.sh"
check "P1-17 ASR reconnect policy smoke" "bash tests/asr_reconnect_policy_smoke.sh"
check "P1-18 real rehearsal script syntax" "test -x scripts/run-real-meeting-rehearsal.sh && bash -n scripts/run-real-meeting-rehearsal.sh"
check "P1-19 full batch script syntax" "test -x tests/run-all.sh && bash -n tests/run-all.sh"
check "P1-20 real meeting smoke script syntax" "test -x scripts/run-real-meeting-smoke.sh && bash -n scripts/run-real-meeting-smoke.sh"
check "P1-21 diarization chunker wired into meeting flow" "grep -q 'DiarizationAudioChunker' Sources/MeetingViewModel.swift"
check "P1-22 diarization provider config placeholders" "grep -q 'diarizationUploadStorage' Sources/Config.swift"
check "P1-23 Fun-ASR provider wired" "grep -q 'DashScopeFunASRProvider' Sources/MeetingViewModel.swift"
check "P1-24 OSS uploader dependency wired" "grep -q 'alibabacloud-oss-swift-sdk-v2' Package.swift && grep -q 'DiarizationOSSUploader' Sources/MeetingViewModel.swift"
check "P1-25 speaker backfill UI wired" "grep -q 'speakerBackfillSegments' Sources/TranscriptView.swift"
check "P1-26 system card type split" "grep -q 'case system' Sources/Models.swift && grep -q 'appendCard(.system' Sources/MeetingViewModel.swift"
check "P1-27 insight dedupe wired" "grep -q 'duplicateInsightSimilarity' Sources/MeetingViewModel.swift && grep -q 'analysis_discarded_duplicate' Sources/MeetingViewModel.swift"
check "P1-28 asr port guard wired" "grep -q 'clearStalePortListeners' Sources/ASRServerManager.swift"
check "P1-29 bridge binds loopback" "grep -q '127.0.0.1:\" + port' asr-bridge/main.go"
check "P1-30 bridge health identity verified" "grep -q 'meetingai-asr-bridge' asr-bridge/main.go && grep -q 'meetingai-asr-bridge' Sources/ASRServerManager.swift"
check "P1-31 default backend is http" "grep -q '?? .http' Sources/MeetingViewModel.swift"
check "P1-32 ai api key env configurable" "grep -q 'apiKeyEnv' Sources/Config.swift"
check "P1-33 complete txt finalize wired" "grep -q 'TranscriptStore.completeTranscriptText' Sources/MeetingViewModel.swift"
check "P1-34 auto skip event denoised" "grep -q 'logSkipEventIfNeeded' Sources/MeetingViewModel.swift"

echo ""
if [ $FAIL -eq 0 ]; then
  echo "All P0+P1 PASSED"
  exit 0
else
  echo "Some P1 checks FAILED"
  exit 1
fi
