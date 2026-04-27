#!/usr/bin/env bash

set -euo pipefail

WHISPER_LARGE_V3_TURBO_MLX_REVISION="${LIVENOTES_WHISPER_LARGE_V3_TURBO_MLX_REVISION:-a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb}"
QWEN3_4B_REVISION="${LIVENOTES_QWEN3_4B_REVISION:-4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25}"

REQUIRED_ARTIFACT_PATHS=(
  "models/whisper-large-v3-turbo/config.json"
  "models/whisper-large-v3-turbo/weights.safetensors"
  "models/qwen3-4b/config.json"
  "models/qwen3-4b/added_tokens.json"
  "models/qwen3-4b/merges.txt"
  "models/qwen3-4b/tokenizer.json"
  "models/qwen3-4b/tokenizer_config.json"
  "models/qwen3-4b/special_tokens_map.json"
  "models/qwen3-4b/vocab.json"
  "models/qwen3-4b/model.safetensors"
  "models/qwen3-4b/model.safetensors.index.json"
)

REMOTE_ARTIFACTS=(
  "https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/$WHISPER_LARGE_V3_TURBO_MLX_REVISION/config.json|models/whisper-large-v3-turbo/config.json|268|b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379"
  "https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/$WHISPER_LARGE_V3_TURBO_MLX_REVISION/weights.safetensors|models/whisper-large-v3-turbo/weights.safetensors|1613977612|951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/config.json|models/qwen3-4b/config.json|937|b5efdcf3b0035a3638e7228dad4d85f5c4a23f156eb7cdb0b44c8366a5d34d9b"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/added_tokens.json|models/qwen3-4b/added_tokens.json|707|c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/merges.txt|models/qwen3-4b/merges.txt|1671853|8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/tokenizer.json|models/qwen3-4b/tokenizer.json|11422654|aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/tokenizer_config.json|models/qwen3-4b/tokenizer_config.json|9706|253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/special_tokens_map.json|models/qwen3-4b/special_tokens_map.json|613|76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/vocab.json|models/qwen3-4b/vocab.json|2776833|ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/model.safetensors|models/qwen3-4b/model.safetensors|2263022529|e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/model.safetensors.index.json|models/qwen3-4b/model.safetensors.index.json|63924|f7825defe5865d179c3b593173d37056be5f202dcb7153985cf74e75ecf1628b"
)

MODEL_ARTIFACT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_ARTIFACT_LOCK_PATH="${LIVENOTES_MODEL_ARTIFACT_LOCK:-$MODEL_ARTIFACT_SCRIPT_DIR/../QualityBenchmarks/model-artifacts.lock.json}"

verify_artifact_source() {
  local root="$1"
  python "$MODEL_ARTIFACT_SCRIPT_DIR/verify-model-artifacts.py" "$root" --lock "${LIVENOTES_MODEL_ARTIFACT_LOCK:-$MODEL_ARTIFACT_LOCK_PATH}" >/dev/null
}
