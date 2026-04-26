#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/model-artifacts.sh"

DESTINATION_ROOT="${1:-$ROOT_DIR/.cache}"
CURL_BIN="${LIVENOTES_CURL_BIN:-curl}"
CURL_HEADER_ARGS=()
if [[ -n "${HF_TOKEN:-}" ]]; then
  CURL_HEADER_ARGS=(-H "Authorization: Bearer $HF_TOKEN")
fi

mkdir -p "$DESTINATION_ROOT"

for entry in "${REMOTE_ARTIFACTS[@]}"; do
  remote_url="${entry%%|*}"
  relative_path="${entry#*|}"
  output_path="$DESTINATION_ROOT/$relative_path"

  if [[ -s "$output_path" ]]; then
    printf 'Using %s\n' "$relative_path"
    continue
  fi

  mkdir -p "$(dirname "$output_path")"
  printf 'Downloading %s\n' "$relative_path"
  curl_args=(
    --fail
    --location
    --retry 5
    --retry-delay 5
    --continue-at -
  )
  if (( ${#CURL_HEADER_ARGS[@]} > 0 )); then
    curl_args+=("${CURL_HEADER_ARGS[@]}")
  fi
  curl_args+=(--output "$output_path" "$remote_url")
  "$CURL_BIN" "${curl_args[@]}"
done

verify_artifact_source "$DESTINATION_ROOT"
printf '%s\n' "$DESTINATION_ROOT"
