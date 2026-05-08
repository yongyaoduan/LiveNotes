#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-loopback-e2e.XXXXXX)"
FIXTURE_PATH="/tmp/livenotes-e2e-audio-fixture.wav"
FIXTURE_PATH_FILE="/tmp/livenotes-e2e-audio-fixture-path.txt"
EXPECTED_PHRASE_FILE="/tmp/livenotes-e2e-expected-phrase.txt"
MIN_DURATION_FILE="/tmp/livenotes-e2e-min-duration-seconds.txt"
MODE_FILE="/tmp/livenotes-e2e-mode.txt"
NATIVE_INFERENCE_FILE="/tmp/livenotes-e2e-native-inference.txt"
PLAYBACK_DEVICE_INDEX_FILE="/tmp/livenotes-e2e-playback-device-index.txt"
FFMPEG_PATH_FILE="/tmp/livenotes-e2e-ffmpeg-path.txt"
SOURCE_AUDIO="${LIVENOTES_E2E_AUDIO_SOURCE:-}"
CLIP_SECONDS="${LIVENOTES_E2E_CLIP_SECONDS:-45}"
EXPECTED_PHRASE="${LIVENOTES_E2E_EXPECTED_PHRASE:-}"
MIN_DURATION_SECONDS="${LIVENOTES_E2E_MIN_DURATION_SECONDS:-20}"
CONFIGURATION="${LIVENOTES_E2E_CONFIGURATION:-Release}"
MODE="${LIVENOTES_E2E_MODE:-audio-file}"
NATIVE_INFERENCE="${LIVENOTES_E2E_NATIVE_INFERENCE:-false}"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required." >&2
    exit 1
  fi
}

choose_input_device() {
  local preferred="${LIVENOTES_TEST_AUDIO_INPUT:-${LIVENOTES_TEST_AUDIO_DEVICE:-}}"
  if [[ -n "$preferred" ]]; then
    printf '%s\n' "$preferred"
    return
  fi
  if SwitchAudioSource -a -t input | grep -qx 'BlackHole 2ch'; then
    printf '%s\n' 'BlackHole 2ch'
    return
  fi
  if SwitchAudioSource -a -t input | grep -qx 'miaowaOutput 2ch'; then
    printf '%s\n' 'miaowaOutput 2ch'
    return
  fi
  if SwitchAudioSource -a -t input | grep -qx 'miaowaInput 2ch'; then
    printf '%s\n' 'miaowaInput 2ch'
    return
  fi
  echo "No supported loopback input device found. Install BlackHole 2ch or set LIVENOTES_TEST_AUDIO_DEVICE." >&2
  exit 1
}

choose_output_device() {
  local input_device="${1:-}"
  local preferred="${LIVENOTES_TEST_AUDIO_OUTPUT:-${LIVENOTES_TEST_AUDIO_DEVICE:-}}"
  if [[ -n "$preferred" ]]; then
    printf '%s\n' "$preferred"
    return
  fi
  if [[ -n "$input_device" ]] && SwitchAudioSource -a -t output | grep -qx "$input_device"; then
    printf '%s\n' "$input_device"
    return
  fi
  if SwitchAudioSource -a -t output | grep -qx 'BlackHole 2ch'; then
    printf '%s\n' 'BlackHole 2ch'
    return
  fi
  if SwitchAudioSource -a -t output | grep -qx 'miaowaOutput 2ch'; then
    printf '%s\n' 'miaowaOutput 2ch'
    return
  fi
  echo "No supported loopback output device found. Install BlackHole 2ch or set LIVENOTES_TEST_AUDIO_OUTPUT." >&2
  exit 1
}

device_uid_for_name() {
  local type="$1"
  local name="$2"
  [[ -n "$name" ]] || return 0
  SwitchAudioSource -f json -a -t "$type" | python3 -c '
import json
import sys

target = sys.argv[1]
for line in sys.stdin:
    if not line.strip():
        continue
    item = json.loads(line)
    if item.get("name") == target:
        print(item.get("uid", ""))
        break
' "$name"
}

restore_audio_device() {
  local type="$1"
  local name="$2"
  local uid="$3"
  if [[ -n "$uid" ]]; then
    SwitchAudioSource -t "$type" -u "$uid" >/dev/null || true
  elif [[ -n "$name" ]]; then
    SwitchAudioSource -t "$type" -s "$name" >/dev/null || true
  fi
}

audiotoolbox_output_index_for_name() {
  local name="$1"
  ffmpeg -hide_banner \
    -f lavfi -i anullsrc=r=48000:cl=mono \
    -t 0.01 \
    -f audiotoolbox \
    -list_devices true \
    - 2>&1 | python3 -c '
import re
import sys

target = sys.argv[1]
for line in sys.stdin:
    match = re.search(r"\[(\d+)\]\s+(.+?),\s+(.+)$", line)
    if match and match.group(2).strip() == target:
        print(match.group(1))
        break
' "$name"
}

prepare_fixture() {
  if [[ -n "$SOURCE_AUDIO" ]]; then
    if [[ ! -f "$SOURCE_AUDIO" ]]; then
      echo "Audio source does not exist: $SOURCE_AUDIO" >&2
      exit 1
    fi
    require_tool ffmpeg
    ffmpeg -y -loglevel error -i "$SOURCE_AUDIO" -t "$CLIP_SECONDS" -ac 1 -ar 48000 -c:a pcm_s16le "$FIXTURE_PATH"
    if [[ -z "$EXPECTED_PHRASE" ]]; then
      EXPECTED_PHRASE="grammar"
    fi
    return
  fi

  require_tool say
  require_tool afconvert
  local aiff_path="$WORK_ROOT/livenotes-e2e-talk.aiff"
  say -v Samantha -r 165 \
    -o "$aiff_path" \
    "Today I want to talk about privacy preserving meeting notes. A reliable local recorder should capture speech, transcribe it, save it, and export a readable transcript."
  afconvert -f WAVE -d LEI16@48000 "$aiff_path" "$FIXTURE_PATH"
  if [[ -z "$EXPECTED_PHRASE" ]]; then
    EXPECTED_PHRASE="privacy preserving meeting notes"
  fi
  MIN_DURATION_SECONDS="${LIVENOTES_E2E_MIN_DURATION_SECONDS:-5}"
}

prepare_fixture

rm -f "$PLAYBACK_DEVICE_INDEX_FILE" "$FFMPEG_PATH_FILE"
printf '%s\n' "$FIXTURE_PATH" > "$FIXTURE_PATH_FILE"
printf '%s\n' "$EXPECTED_PHRASE" > "$EXPECTED_PHRASE_FILE"
printf '%s\n' "$MIN_DURATION_SECONDS" > "$MIN_DURATION_FILE"
printf '%s\n' "$MODE" > "$MODE_FILE"
printf '%s\n' "$NATIVE_INFERENCE" > "$NATIVE_INFERENCE_FILE"

if [[ "$MODE" == "loopback" ]]; then
  require_tool SwitchAudioSource
  require_tool ffmpeg
  INPUT_DEVICE="$(choose_input_device)"
  OUTPUT_DEVICE="$(choose_output_device "$INPUT_DEVICE")"
  PLAYBACK_DEVICE_INDEX="$(audiotoolbox_output_index_for_name "$OUTPUT_DEVICE")"
  if [[ -z "$PLAYBACK_DEVICE_INDEX" ]]; then
    echo "Could not find AudioToolbox output device index for $OUTPUT_DEVICE." >&2
    exit 1
  fi
  printf '%s\n' "$PLAYBACK_DEVICE_INDEX" > "$PLAYBACK_DEVICE_INDEX_FILE"
  command -v ffmpeg > "$FFMPEG_PATH_FILE"
  OLD_INPUT="$(SwitchAudioSource -c -t input)"
  OLD_OUTPUT="$(SwitchAudioSource -c -t output)"
  OLD_SYSTEM="$(SwitchAudioSource -c -t system || true)"
  OLD_INPUT_UID="$(device_uid_for_name input "$OLD_INPUT")"
  OLD_OUTPUT_UID="$(device_uid_for_name output "$OLD_OUTPUT")"
  OLD_SYSTEM_UID="$(device_uid_for_name output "$OLD_SYSTEM")"

  restore_audio() {
    restore_audio_device input "$OLD_INPUT" "$OLD_INPUT_UID"
    restore_audio_device output "$OLD_OUTPUT" "$OLD_OUTPUT_UID"
    if [[ -n "$OLD_SYSTEM" ]]; then
      restore_audio_device system "$OLD_SYSTEM" "$OLD_SYSTEM_UID"
    fi
  }
  trap 'restore_audio; cleanup' EXIT INT TERM

  SwitchAudioSource -t input -s "$INPUT_DEVICE" >/dev/null
elif [[ "$MODE" != "audio-file" ]]; then
  echo "Unsupported LIVENOTES_E2E_MODE: $MODE" >&2
  exit 1
fi

xcodebuild test \
  -project "$ROOT_DIR/LiveNotes.xcodeproj" \
  -scheme LiveNotes \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:LiveNotesUITests/LiveNotesUITests/testProductionLoopbackRecordsTranscribesSavesAndExports
