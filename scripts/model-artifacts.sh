#!/usr/bin/env bash

set -euo pipefail

WHISPER_MEDIUM_MLX_REVISION="${LIVENOTES_WHISPER_MEDIUM_MLX_REVISION:-7fc08c4eac4c316526498f147dfdee6f6303f975}"
QWEN3_4B_REVISION="${LIVENOTES_QWEN3_4B_REVISION:-4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25}"
QWEN3_1_7B_REVISION="${LIVENOTES_QWEN3_1_7B_REVISION:-3b1b1768f8f8cf8351c712464f906e86c2b8269e}"

REQUIRED_ARTIFACT_PATHS=(
  "models/whisper-medium/config.json"
  "models/whisper-medium/weights.npz"
  "models/qwen3-4b/config.json"
  "models/qwen3-4b/added_tokens.json"
  "models/qwen3-4b/merges.txt"
  "models/qwen3-4b/tokenizer.json"
  "models/qwen3-4b/tokenizer_config.json"
  "models/qwen3-4b/special_tokens_map.json"
  "models/qwen3-4b/vocab.json"
  "models/qwen3-4b/model.safetensors"
  "models/qwen3-4b/model.safetensors.index.json"
  "models/qwen3-1.7b/config.json"
  "models/qwen3-1.7b/added_tokens.json"
  "models/qwen3-1.7b/merges.txt"
  "models/qwen3-1.7b/tokenizer.json"
  "models/qwen3-1.7b/tokenizer_config.json"
  "models/qwen3-1.7b/special_tokens_map.json"
  "models/qwen3-1.7b/vocab.json"
  "models/qwen3-1.7b/model.safetensors"
  "models/qwen3-1.7b/model.safetensors.index.json"
)

REMOTE_ARTIFACTS=(
  "https://huggingface.co/mlx-community/whisper-medium-mlx/resolve/$WHISPER_MEDIUM_MLX_REVISION/config.json|models/whisper-medium/config.json"
  "https://huggingface.co/mlx-community/whisper-medium-mlx/resolve/$WHISPER_MEDIUM_MLX_REVISION/weights.npz|models/whisper-medium/weights.npz"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/config.json|models/qwen3-4b/config.json"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/added_tokens.json|models/qwen3-4b/added_tokens.json"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/merges.txt|models/qwen3-4b/merges.txt"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/tokenizer.json|models/qwen3-4b/tokenizer.json"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/tokenizer_config.json|models/qwen3-4b/tokenizer_config.json"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/special_tokens_map.json|models/qwen3-4b/special_tokens_map.json"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/vocab.json|models/qwen3-4b/vocab.json"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/model.safetensors|models/qwen3-4b/model.safetensors"
  "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/$QWEN3_4B_REVISION/model.safetensors.index.json|models/qwen3-4b/model.safetensors.index.json"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/config.json|models/qwen3-1.7b/config.json"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/added_tokens.json|models/qwen3-1.7b/added_tokens.json"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/merges.txt|models/qwen3-1.7b/merges.txt"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/tokenizer.json|models/qwen3-1.7b/tokenizer.json"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/tokenizer_config.json|models/qwen3-1.7b/tokenizer_config.json"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/special_tokens_map.json|models/qwen3-1.7b/special_tokens_map.json"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/vocab.json|models/qwen3-1.7b/vocab.json"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/model.safetensors|models/qwen3-1.7b/model.safetensors"
  "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$QWEN3_1_7B_REVISION/model.safetensors.index.json|models/qwen3-1.7b/model.safetensors.index.json"
)

verify_artifact_source() {
  local root="$1"
  local missing=()

  for relative_path in "${REQUIRED_ARTIFACT_PATHS[@]}"; do
    if [[ ! -s "$root/$relative_path" ]]; then
      missing+=("$relative_path")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf 'Live Notes model bundle is missing required files at %s:\n' "$root" >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
}
