#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-model-verifier-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

PROFILE_LOCK="$WORK_ROOT/profile-lock.json"
PROFILE_ROOT="$WORK_ROOT/profile-root"
mkdir -p "$PROFILE_ROOT"

cat > "$PROFILE_LOCK" <<'JSON'
{
  "schema": 1,
  "default_profile": {
    "runtime": "mlx",
    "transcription": "whisper",
    "summarization": "qwen",
    "translation": "candidate"
  },
  "models": [
    {
      "id": "whisper",
      "task": "transcription",
      "bundled": true,
      "artifacts": []
    },
    {
      "id": "qwen",
      "task": "summarization",
      "bundled": true,
      "artifacts": []
    },
    {
      "id": "candidate",
      "task": "translation",
      "bundled": false,
      "artifacts": []
    }
  ]
}
JSON

PROFILE_LOG="$WORK_ROOT/profile.log"
if python "$ROOT_DIR/scripts/verify-model-artifacts.py" "$PROFILE_ROOT" --lock "$PROFILE_LOCK" >"$PROFILE_LOG" 2>&1; then
  echo "Expected non-bundled default profile validation to fail" >&2
  exit 1
fi
grep -q 'default_profile translation uses non-bundled model candidate' "$PROFILE_LOG"
if grep -q 'Traceback' "$PROFILE_LOG"; then
  echo "Verifier must not traceback on default profile validation" >&2
  exit 1
fi

TASK_LOCK="$WORK_ROOT/task-lock.json"
cat > "$TASK_LOCK" <<'JSON'
{
  "schema": 1,
  "default_profile": {
    "runtime": "mlx",
    "transcription": "whisper",
    "summarization": "qwen",
    "translation": "qwen"
  },
  "models": [
    {
      "id": "whisper",
      "task": "transcription",
      "bundled": true,
      "artifacts": []
    },
    {
      "id": "qwen",
      "task": "summarization",
      "bundled": true,
      "artifacts": []
    }
  ]
}
JSON

TASK_LOG="$WORK_ROOT/task.log"
if python "$ROOT_DIR/scripts/verify-model-artifacts.py" "$PROFILE_ROOT" --lock "$TASK_LOCK" >"$TASK_LOG" 2>&1; then
  echo "Expected default profile task validation to fail" >&2
  exit 1
fi
grep -q 'default_profile translation uses qwen' "$TASK_LOG"
if grep -q 'Traceback' "$TASK_LOG"; then
  echo "Verifier must not traceback on task validation" >&2
  exit 1
fi

SAFE_ROOT="$WORK_ROOT/safetensors-root"
SAFE_LOCK="$WORK_ROOT/safetensors-lock.json"
mkdir -p "$SAFE_ROOT/models/whisper"
printf 'bad' > "$SAFE_ROOT/models/whisper/weights.safetensors"

cat > "$SAFE_LOCK" <<'JSON'
{
  "schema": 1,
  "default_profile": {
    "runtime": "mlx",
    "transcription": "whisper",
    "summarization": "qwen",
    "translation": "qwen"
  },
  "models": [
    {
      "id": "whisper",
      "task": "transcription",
      "bundled": true,
      "artifacts": [
        {
          "path": "models/whisper/weights.safetensors",
          "type": "safetensors"
        }
      ]
    },
    {
      "id": "qwen",
      "tasks": ["summarization", "translation"],
      "bundled": true,
      "artifacts": []
    }
  ]
}
JSON

SAFE_LOG="$WORK_ROOT/safetensors.log"
if python "$ROOT_DIR/scripts/verify-model-artifacts.py" "$SAFE_ROOT" --lock "$SAFE_LOCK" >"$SAFE_LOG" 2>&1; then
  echo "Expected truncated safetensors validation to fail" >&2
  exit 1
fi
grep -q 'has an incomplete safetensors header' "$SAFE_LOG"
if grep -q 'Traceback' "$SAFE_LOG"; then
  echo "Verifier must not traceback on invalid safetensors" >&2
  exit 1
fi

CONFIG_ROOT="$WORK_ROOT/config-root"
CONFIG_LOCK="$WORK_ROOT/config-lock.json"
mkdir -p "$CONFIG_ROOT/models/qwen3-4b"
printf '{bad json' > "$CONFIG_ROOT/models/qwen3-4b/config.json"

cat > "$CONFIG_LOCK" <<'JSON'
{
  "schema": 1,
  "default_profile": {
    "runtime": "mlx",
    "transcription": "whisper",
    "summarization": "qwen3-4b-4bit",
    "translation": "qwen3-4b-4bit"
  },
  "models": [
    {
      "id": "whisper",
      "task": "transcription",
      "bundled": true,
      "artifacts": []
    },
    {
      "id": "qwen3-4b-4bit",
      "tasks": ["summarization", "translation"],
      "bundled": true,
      "artifacts": [],
      "precision": {
        "base_compute_dtype": "bfloat16",
        "quantization_bits": 4,
        "quantization_group_size": 64,
        "quantized_weight_dtype": "U32",
        "scale_bias_dtype": "BF16"
      }
    }
  ]
}
JSON

CONFIG_LOG="$WORK_ROOT/config.log"
if python "$ROOT_DIR/scripts/verify-model-artifacts.py" "$CONFIG_ROOT" --lock "$CONFIG_LOCK" >"$CONFIG_LOG" 2>&1; then
  echo "Expected malformed config validation to fail" >&2
  exit 1
fi
grep -q 'config.json is not valid JSON' "$CONFIG_LOG"
if grep -q 'Traceback' "$CONFIG_LOG"; then
  echo "Verifier must not traceback on malformed config JSON" >&2
  exit 1
fi

printf '%s\n' "$WORK_ROOT"
