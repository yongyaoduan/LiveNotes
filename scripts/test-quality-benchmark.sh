#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-quality-benchmark-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

REPORT_PATH="$WORK_ROOT/report.json"
"$ROOT_DIR/scripts/run-quality-benchmark.sh" \
  --mode fixture \
  --tasks transcription,translation,topic,public_audio \
  --output "$REPORT_PATH" >/dev/null

python - "$REPORT_PATH" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    report = json.load(handle)

assert report["passed"] is True
assert report["results"]["transcription"]["passed"] is True
assert report["results"]["translation"]["passed"] is True
assert report["results"]["topic_summary"]["passed"] is True
assert report["results"]["transcription"]["recommended_candidate"] == "whisper-large-v3-turbo"
assert report["results"]["translation"]["recommended_candidate"] == "qwen3-4b-4bit"
assert report["results"]["topic_summary"]["recommended_candidate"] == "qwen3-4b-4bit"
assert report["results"]["public_audio"]["passed"] is True
assert report["results"]["public_audio"]["passed_cases"] == report["results"]["public_audio"]["total_cases"]
assert len(report["results"]["transcription"]["candidates"]) == 1
assert len(report["results"]["translation"]["candidates"]) == 1
assert len(report["results"]["topic_summary"]["candidates"]) == 1
PY

MODEL_SELECTION_FAILURE="$WORK_ROOT/model-selection-fixture.log"
if "$ROOT_DIR/scripts/run-quality-benchmark.sh" \
  --mode fixture \
  --benchmark-profile model-selection \
  --tasks public_asr_selection,translation_selection,topic_selection \
  --sample-count 100 \
  --output "$WORK_ROOT/model-selection.json" >"$MODEL_SELECTION_FAILURE" 2>&1; then
  echo "Expected model-selection benchmark to require live mode" >&2
  exit 1
fi
grep -q "Model selection benchmarks must run in live mode." "$MODEL_SELECTION_FAILURE"

MODEL_SELECTION_TASK_FAILURE="$WORK_ROOT/model-selection-tasks.log"
if python "$ROOT_DIR/QualityBenchmarks/run_quality_benchmark.py" \
  --mode live \
  --benchmark-profile model-selection \
  --tasks public_asr_selection \
  --sample-count 100 \
  --output "$WORK_ROOT/incomplete-model-selection.json" >"$MODEL_SELECTION_TASK_FAILURE" 2>&1; then
  echo "Expected model-selection benchmark to require every selection task" >&2
  exit 1
fi
grep -q "Model selection benchmarks must include public ASR, translation, and topic selection." "$MODEL_SELECTION_TASK_FAILURE"

python - "$ROOT_DIR" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types

root = Path(sys.argv[1])
module_path = root / "QualityBenchmarks" / "run_quality_benchmark.py"
spec = importlib.util.spec_from_file_location("quality_benchmark", module_path)
benchmark = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = benchmark
spec.loader.exec_module(benchmark)

candidate = benchmark.TRANSCRIPTION_CANDIDATES["whisper-large-v3-turbo"]
failed_asr_summary = benchmark.summarize_public_asr_candidate(
    candidate,
    [
        {
            "case_id": f"case_{index}",
            "source": "ami",
            "wer": 0.01 if index < 94 else 0.90,
            "latency_seconds": 0.10,
            "real_time_factor": 0.01,
            "passed": index < 94,
        }
        for index in range(100)
    ],
)
assert failed_asr_summary["passed"] is False
passing_asr_summary = benchmark.summarize_public_asr_candidate(
    candidate,
    [
        {
            "case_id": f"case_{index}",
            "source": "ami" if index < 50 else "tedlium",
            "wer": 0.08 if index < 95 else 0.49,
            "latency_seconds": 0.10,
            "real_time_factor": 0.01,
            "passed": index < 95,
        }
        for index in range(100)
    ],
)
assert passing_asr_summary["passed"] is True
assert passing_asr_summary["case_pass_rate"] == 0.95
try:
    benchmark.run_public_asr_selection("fixture", ["whisper-large-v3-turbo"], 99)
    raise AssertionError("Expected sample-count validation to fail.")
except ValueError as error:
    assert "at least 100 samples" in str(error)

with tempfile.TemporaryDirectory(prefix="livenotes-cache-test.") as temp_dir:
    benchmark_cache_root = Path(temp_dir) / "benchmark-cache"
    os.environ.pop("HF_HOME", None)
    os.environ.pop("HF_HUB_CACHE", None)
    os.environ.pop("HF_DATASETS_CACHE", None)
    os.environ.pop("TRANSFORMERS_CACHE", None)
    os.environ["LIVENOTES_BENCHMARK_CACHE_ROOT"] = str(benchmark_cache_root)

    fake_hub = types.ModuleType("huggingface_hub")

    def snapshot_download(**kwargs):
        cache_dir = Path(kwargs["cache_dir"])
        assert cache_dir == benchmark_cache_root / "huggingface" / "hub"
        return str(cache_dir / "snapshot")

    fake_hub.snapshot_download = snapshot_download
    sys.modules["huggingface_hub"] = fake_hub
    with benchmark.benchmark_cache_scope("live"):
        assert Path(os.environ["HF_HOME"]) == benchmark_cache_root / "huggingface"
        assert Path(os.environ["HF_HUB_CACHE"]) == benchmark_cache_root / "huggingface" / "hub"
        assert Path(os.environ["HF_DATASETS_CACHE"]) == benchmark_cache_root / "huggingface" / "datasets"
        assert Path(os.environ["TRANSFORMERS_CACHE"]) == benchmark_cache_root / "huggingface" / "transformers"
        assert benchmark.locked_snapshot_path("org/model", "rev") == str(
            benchmark_cache_root / "huggingface" / "hub" / "snapshot"
        )

assert benchmark.word_error_rate(
    "several years ago here at ted peter skillman introduced a design challenge",
    "Several years ago, here at TED, Peter Skillman introduced a design challenge.",
) == 0.0

prompt = benchmark.topic_boundary_prompt([
    "Notebook setup starts with dependencies.",
    "Validation accuracy changed after the learning rate update.",
    "The training curve should be compared before changing another setting.",
    "A stable validation curve is more useful than one lucky training batch.",
])
assert "[0,1,1,1]" in prompt
assert "[0,0,0,1]" in prompt
assert "[0,0,1,1]" in prompt
assert "Example: four sentences in two topics should return [0,0,1,1]" not in prompt
sensitive_prompt = benchmark.sensitive_topic_boundary_prompt([
    "Notebook setup starts with dependencies.",
    "Validation accuracy changed after the learning rate update.",
    "The training curve should be compared before changing another setting.",
    "A stable validation curve is more useful than one lucky training batch.",
])
assert "A one-sentence opening topic is valid." in sensitive_prompt
assert benchmark.has_leading_topic_boundary([0, 1, 1, 1], 4) is True
assert benchmark.has_leading_topic_boundary([0, 0, 1, 1], 4) is False
assert benchmark.leading_singleton_topic_ids(4) == [0, 1, 1, 1]
PY

FAILING_READINESS="$WORK_ROOT/failing-readiness.sh"
cat > "$FAILING_READINESS" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

printf 'warning: No matching test cases were run\n'
exit 0
SCRIPT
chmod +x "$FAILING_READINESS"

PIPELINE_FAIL_REPORT="$WORK_ROOT/pipeline-fail.json"
if LIVENOTES_RELEASE_READINESS_COMMAND="$FAILING_READINESS" \
  "$ROOT_DIR/scripts/run-quality-benchmark.sh" \
    --mode fixture \
    --require-swift-pipeline \
    --output "$PIPELINE_FAIL_REPORT" >/dev/null 2>&1; then
  echo "Expected Swift pipeline gate to reject empty pipeline tests" >&2
  exit 1
fi

PASSING_READINESS="$WORK_ROOT/passing-readiness.sh"
cat > "$PASSING_READINESS" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

printf 'Release readiness passed.\n'
SCRIPT
chmod +x "$PASSING_READINESS"

PIPELINE_PASS_REPORT="$WORK_ROOT/pipeline-pass.json"
LIVENOTES_RELEASE_READINESS_COMMAND="$PASSING_READINESS" \
  "$ROOT_DIR/scripts/run-quality-benchmark.sh" \
    --mode fixture \
    --require-swift-pipeline \
    --output "$PIPELINE_PASS_REPORT" >/dev/null

python - "$PIPELINE_PASS_REPORT" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)

assert report["passed"] is True
assert report["results"]["swift_pipeline"]["passed"] is True
PY

printf '%s\n' "$REPORT_PATH"
