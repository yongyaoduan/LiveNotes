#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-homebrew-cask-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

CASK_PATH="$WORK_ROOT/livenotes.rb"
"$ROOT_DIR/scripts/write-homebrew-cask.sh" \
  "0.1.0" \
  "https://github.com/yongyaoduan/LiveNotes/releases/download/v0.1.0/LiveNotes-0.1.0.zip" \
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  "$CASK_PATH" >/dev/null

ruby -c "$CASK_PATH" >/dev/null

grep -q 'cask "livenotes"' "$CASK_PATH"
grep -q 'LiveNotesArtifacts' "$CASK_PATH"
grep -q 'whisper-medium-mlx' "$CASK_PATH"
grep -q 'Qwen3-4B-4bit' "$CASK_PATH"
grep -q 'Qwen3-1.7B-4bit' "$CASK_PATH"
grep -q 'app "LiveNotes.app"' "$CASK_PATH"

printf '%s\n' "$CASK_PATH"
