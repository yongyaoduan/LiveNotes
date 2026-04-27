#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_FILE="$ROOT_DIR/LiveNotesCore/Sources/LiveNotesCore/RecordingPipeline.swift"
HELPER_FILE="${LIVENOTES_MLX_HELPER:-$ROOT_DIR/scripts/livenotes_mlx_pipeline.py}"
INTEGRATION_TEST="$ROOT_DIR/LiveNotesCore/Tests/LiveNotesCoreTests/RecordingPipelineIntegrationTests.swift"
REPORT_PATH="$ROOT_DIR/LiveNotesCore/.build/livenotes-recording-pipeline-report.json"
ARTIFACT_ROOT="${LIVENOTES_MODEL_ARTIFACT_ROOT:-$ROOT_DIR/.cache/LiveNotesArtifacts}"
PYTHON_BIN="${LIVENOTES_PYTHON:-python3}"
WORK_ROOT="$(mktemp -d /tmp/livenotes-release-readiness.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT
BENCHMARK_CACHE_ROOT="${LIVENOTES_BENCHMARK_CACHE_ROOT:-$WORK_ROOT/benchmark-cache}"
HF_ROOT="$BENCHMARK_CACHE_ROOT/huggingface"
export HF_HOME="$HF_ROOT"
export HF_HUB_CACHE="$HF_ROOT/hub"
export HF_DATASETS_CACHE="$HF_ROOT/datasets"
export TRANSFORMERS_CACHE="$HF_ROOT/transformers"
mkdir -p "$HF_HUB_CACHE" "$HF_DATASETS_CACHE" "$TRANSFORMERS_CACHE"

if [[ ! -f "$PIPELINE_FILE" ]]; then
  echo "Release blocked: production recording pipeline is missing." >&2
  exit 1
fi

if ! grep -q '^@preconcurrency import AVFoundation$' "$PIPELINE_FILE" ||
   ! grep -q 'AVAudioEngine()' "$PIPELINE_FILE" ||
   ! grep -q 'LocalMLXInferenceRunner' "$PIPELINE_FILE"; then
  echo "Release blocked: recording pipeline must include AVAudioEngine capture and local MLX inference." >&2
  exit 1
fi

if [[ ! -f "$HELPER_FILE" ]] || ! "$PYTHON_BIN" - "$HELPER_FILE" <<'PY'
import ast
import sys
from pathlib import Path

tree = ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(alias.name.split(".")[0] for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module:
        imports.add(node.module.split(".")[0])
required = {"mlx_whisper", "mlx_lm"}
missing = sorted(required - imports)
if missing:
    raise SystemExit(1)
PY
then
  echo "Release blocked: local MLX inference helper is not enabled." >&2
  exit 1
fi

if [[ ! -f "$INTEGRATION_TEST" ]] ||
   ! grep -q 'livePipelineRunsLocalMLXInference' "$INTEGRATION_TEST"; then
  echo "Release blocked: live recording pipeline integration test is missing." >&2
  exit 1
fi

PREPARE_ARTIFACTS_COMMAND="${LIVENOTES_PREPARE_ARTIFACTS_COMMAND:-$ROOT_DIR/scripts/prepare-bundled-artifacts.sh}"
"$PREPARE_ARTIFACTS_COMMAND" "$ARTIFACT_ROOT" >/dev/null
VERIFY_ARTIFACTS_COMMAND="${LIVENOTES_VERIFY_ARTIFACTS_COMMAND:-$ROOT_DIR/scripts/verify-model-artifacts.py}"
"$VERIFY_ARTIFACTS_COMMAND" "$ARTIFACT_ROOT" >/dev/null

AUDIO_PATH="${LIVENOTES_RECORDING_PIPELINE_AUDIO:-$WORK_ROOT/public-audio.wav}"
if [[ -z "${LIVENOTES_RECORDING_PIPELINE_AUDIO:-}" ]]; then
  "$PYTHON_BIN" - "$ROOT_DIR" "$AUDIO_PATH" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download

root = Path(sys.argv[1])
output_path = Path(sys.argv[2])
case = json.loads((root / "QualityBenchmarks" / "public_audio_cases.json").read_text(encoding="utf-8"))[0]
parquet_path = hf_hub_download(
    repo_id=case["dataset"],
    repo_type="dataset",
    filename=case["parquet_file"],
    revision=case["dataset_revision"],
    cache_dir=os.environ["HF_HUB_CACHE"],
)
table = pq.read_table(parquet_path, columns=["id", "text", "audio", "audio_length_s"])
ids = table.column("id").to_pylist()
try:
    row_index = ids.index(case["record_id"])
except ValueError:
    raise SystemExit("Release blocked: public audio case was not found.")
item = table.slice(row_index, 1).to_pylist()[0]
reference = str(item.get("text", "")).strip()
reference_hash = hashlib.sha256(reference.encode("utf-8")).hexdigest()
if reference_hash != case["reference_sha256"]:
    raise SystemExit("Release blocked: public audio reference changed.")
audio = item["audio"]
if audio.get("bytes"):
    output_path.write_bytes(audio["bytes"])
elif audio.get("path"):
    output_path.write_bytes(Path(audio["path"]).read_bytes())
else:
    raise SystemExit("Release blocked: public audio case has no audio bytes.")
PY
fi

if [[ ! -s "$AUDIO_PATH" ]]; then
  echo "Release blocked: public audio fixture is missing." >&2
  exit 1
fi

rm -f "$REPORT_PATH"

(
  cd "$ROOT_DIR/LiveNotesCore"
  LIVENOTES_RECORDING_PIPELINE_LIVE=1 \
  LIVENOTES_RECORDING_PIPELINE_CAPTURE_LIVE="${LIVENOTES_RECORDING_PIPELINE_CAPTURE_LIVE:-1}" \
  LIVENOTES_RECORDING_PIPELINE_CAPTURE_AUDIO="${LIVENOTES_RECORDING_PIPELINE_CAPTURE_AUDIO:-$WORK_ROOT/captured-audio.m4a}" \
  LIVENOTES_RECORDING_PIPELINE_CAPTURE_SECONDS="${LIVENOTES_RECORDING_PIPELINE_CAPTURE_SECONDS:-2}" \
  LIVENOTES_RECORDING_PIPELINE_AUDIO="$AUDIO_PATH" \
  LIVENOTES_MODEL_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
  LIVENOTES_MLX_HELPER="$HELPER_FILE" \
  LIVENOTES_RECORDING_PIPELINE_REPORT="$REPORT_PATH" \
  LIVENOTES_PYTHON="$PYTHON_BIN" \
    swift test --disable-sandbox --filter RecordingPipelineIntegrationTests
)

"$PYTHON_BIN" - "$REPORT_PATH" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit("Release blocked: recording pipeline report was not written.")

report = json.loads(path.read_text(encoding="utf-8"))
required = {
    "audio_capture": "passed",
    "local_mlx_inference": "passed",
    "end_to_end_recording_pipeline": "passed",
}
for key, expected in required.items():
    if report.get(key) != expected:
        raise SystemExit(f"Release blocked: {key} did not pass.")

metrics = report.get("metrics", {})
minimums = {
    "audio_duration_seconds": 1,
    "transcript_segments": 1,
    "translation_segments": 1,
    "topic_count": 1,
}
for key, minimum in minimums.items():
    if metrics.get(key, 0) < minimum:
        raise SystemExit(f"Release blocked: {key} is below the release minimum.")

if metrics.get("real_time_factor", 999) > 6:
    raise SystemExit("Release blocked: recording pipeline is slower than the release threshold.")

if report.get("model_runtime") != "Local MLX":
    raise SystemExit("Release blocked: model runtime must be Local MLX.")
PY

printf 'Release readiness passed.\n'
