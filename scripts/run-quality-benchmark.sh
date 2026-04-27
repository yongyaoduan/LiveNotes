#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="fixture"
BENCHMARK_PROFILE="release-smoke"
TASKS=""
TRANSLATION_CANDIDATES="qwen3-4b-4bit"
TRANSCRIPTION_CANDIDATES="whisper-large-v3-turbo"
TOPIC_CANDIDATES="qwen3-4b-4bit"
OUTPUT_PATH="$ROOT_DIR/dist/quality-benchmark/latest.json"
REQUIRE_SWIFT_PIPELINE=0
SAMPLE_COUNT=""
REQUIRED_TRANSCRIPTION_DEFAULT="whisper-large-v3-turbo"
REQUIRED_TRANSLATION_DEFAULT="qwen3-4b-4bit"
REQUIRED_TOPIC_DEFAULT="qwen3-4b-4bit"

while (( $# > 0 )); do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --tasks)
      TASKS="$2"
      shift 2
      ;;
    --benchmark-profile)
      BENCHMARK_PROFILE="$2"
      shift 2
      ;;
    --sample-count)
      SAMPLE_COUNT="$2"
      shift 2
      ;;
    --translation-candidates)
      TRANSLATION_CANDIDATES="$2"
      shift 2
      ;;
    --topic-candidates)
      TOPIC_CANDIDATES="$2"
      shift 2
      ;;
    --transcription-candidates)
      TRANSCRIPTION_CANDIDATES="$2"
      shift 2
      ;;
    --required-transcription-default)
      REQUIRED_TRANSCRIPTION_DEFAULT="$2"
      shift 2
      ;;
    --required-translation-default)
      REQUIRED_TRANSLATION_DEFAULT="$2"
      shift 2
      ;;
    --required-topic-default)
      REQUIRED_TOPIC_DEFAULT="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --require-swift-pipeline)
      REQUIRE_SWIFT_PIPELINE=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if [[ -z "$TASKS" ]]; then
  if [[ "$BENCHMARK_PROFILE" == "model-selection" ]]; then
    TASKS="public_asr_selection,translation_selection,topic_selection"
  else
    TASKS="transcription,translation,topic,public_audio"
  fi
fi

ARGS=(
  --mode "$MODE"
  --benchmark-profile "$BENCHMARK_PROFILE"
  --tasks "$TASKS"
  --transcription-candidates "$TRANSCRIPTION_CANDIDATES"
  --translation-candidates "$TRANSLATION_CANDIDATES"
  --topic-candidates "$TOPIC_CANDIDATES"
  --required-transcription-default "$REQUIRED_TRANSCRIPTION_DEFAULT"
  --required-translation-default "$REQUIRED_TRANSLATION_DEFAULT"
  --required-topic-default "$REQUIRED_TOPIC_DEFAULT"
  --output "$OUTPUT_PATH"
)

if [[ -n "$SAMPLE_COUNT" ]]; then
  ARGS+=(--sample-count "$SAMPLE_COUNT")
fi

if [[ "$REQUIRE_SWIFT_PIPELINE" == "1" ]]; then
  ARGS+=(--require-swift-pipeline)
fi

python "$ROOT_DIR/QualityBenchmarks/run_quality_benchmark.py" "${ARGS[@]}"
