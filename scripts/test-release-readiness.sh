#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-release-readiness-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

FAKE_ARTIFACTS="$WORK_ROOT/artifacts"
FAKE_AUDIO="$WORK_ROOT/public-audio.wav"
FAKE_HELPER="$WORK_ROOT/livenotes_mlx_pipeline.py"
FAKE_PREPARE="$WORK_ROOT/prepare-artifacts.sh"
FAKE_VERIFY="$WORK_ROOT/verify-artifacts.sh"

mkdir -p "$FAKE_ARTIFACTS/models/whisper-large-v3-turbo" "$FAKE_ARTIFACTS/models/qwen3-4b"
printf 'audio\n' > "$FAKE_AUDIO"

cat > "$FAKE_PREPARE" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

mkdir -p "$1"
printf '%s\n' "$1"
SCRIPT
chmod +x "$FAKE_PREPARE"

cat > "$FAKE_VERIFY" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

printf '%s\n' "$1"
SCRIPT
chmod +x "$FAKE_VERIFY"

cat > "$FAKE_HELPER" <<'PY'
#!/usr/bin/env python3

import json
import sys

if False:
    import mlx_whisper
    from mlx_lm import load

payload = {
    "transcript": [
        {
            "startTime": 0,
            "endTime": 3,
            "text": "Real audio pipeline test.",
            "translation": "Real audio pipeline test translation.",
            "confidence": "high",
        }
    ],
    "topics": [
        {
            "title": "Pipeline Test",
            "startTime": 0,
            "endTime": 3,
            "summary": "The local pipeline produced transcript, translation, and topics.",
            "keyPoints": ["The local pipeline ran."],
            "questions": [],
        }
    ],
    "metrics": {
        "audioDurationSeconds": 3,
        "transcriptSegments": 1,
        "translationSegments": 1,
        "topicCount": 1,
        "totalProcessingSeconds": 0.2,
        "realTimeFactor": 0.07,
    },
}
json.dump(payload, sys.stdout, ensure_ascii=False)
PY
chmod +x "$FAKE_HELPER"

LOG_PATH="$WORK_ROOT/release-readiness.log"
LIVENOTES_MODEL_ARTIFACT_ROOT="$FAKE_ARTIFACTS" \
LIVENOTES_RECORDING_PIPELINE_AUDIO="$FAKE_AUDIO" \
LIVENOTES_RECORDING_PIPELINE_CAPTURE_LIVE=0 \
LIVENOTES_MLX_HELPER="$FAKE_HELPER" \
LIVENOTES_PREPARE_ARTIFACTS_COMMAND="$FAKE_PREPARE" \
LIVENOTES_VERIFY_ARTIFACTS_COMMAND="$FAKE_VERIFY" \
  "$ROOT_DIR/scripts/check-release-readiness.sh" >"$LOG_PATH" 2>&1

grep -q 'Release readiness passed.' "$LOG_PATH"

FAKE_PYTHON="$WORK_ROOT/python-cache-check.sh"
cat > "$FAKE_PYTHON" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -eq 3 && "$1" == "-" ]]; then
  expected_root="$LIVENOTES_BENCHMARK_CACHE_ROOT/huggingface"
  [[ "${HF_HOME:-}" == "$expected_root" ]]
  [[ "${HF_HUB_CACHE:-}" == "$expected_root/hub" ]]
  [[ "${HF_DATASETS_CACHE:-}" == "$expected_root/datasets" ]]
  [[ "${TRANSFORMERS_CACHE:-}" == "$expected_root/transformers" ]]
  printf 'audio\n' > "$3"
  exit 0
fi

exec python3 "$@"
SCRIPT
chmod +x "$FAKE_PYTHON"

CACHE_LOG_PATH="$WORK_ROOT/release-readiness-cache.log"
LIVENOTES_MODEL_ARTIFACT_ROOT="$FAKE_ARTIFACTS" \
LIVENOTES_BENCHMARK_CACHE_ROOT="$WORK_ROOT/benchmark-cache" \
LIVENOTES_RECORDING_PIPELINE_CAPTURE_LIVE=0 \
LIVENOTES_MLX_HELPER="$FAKE_HELPER" \
LIVENOTES_PREPARE_ARTIFACTS_COMMAND="$FAKE_PREPARE" \
LIVENOTES_VERIFY_ARTIFACTS_COMMAND="$FAKE_VERIFY" \
LIVENOTES_PYTHON="$FAKE_PYTHON" \
  "$ROOT_DIR/scripts/check-release-readiness.sh" >"$CACHE_LOG_PATH" 2>&1

grep -q 'Release readiness passed.' "$CACHE_LOG_PATH"
printf '%s\n' "$LOG_PATH"
