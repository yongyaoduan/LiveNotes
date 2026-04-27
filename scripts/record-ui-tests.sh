#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/ui-evidence}"
VIDEO_PATH="$OUTPUT_DIR/LiveNotesUITests.mov"
TIMELINE_VIDEO_PATH="$OUTPUT_DIR/LiveNotesUITests-screenshot-timeline.mov"
SCREENSHOTS_CONTACT_SHEET_PATH="$OUTPUT_DIR/screenshots-contact-sheet.jpg"
CONTACT_SHEETS_DIR="$OUTPUT_DIR/contact-sheets"
ATTACHMENTS_DIR="$OUTPUT_DIR/attachments"
SOURCE_ATTACHMENTS_DIR="${LIVENOTES_UI_EVIDENCE_SOURCE_DIR:-$HOME/Library/Containers/app.livenotes.macUITests.xctrunner/Data/Library/Caches/LiveNotesUITestEvidence}"
LOG_PATH="$OUTPUT_DIR/xcodebuild.log"
RUN_UI_TESTS_BIN="${LIVENOTES_RUN_UI_TESTS_BIN:-$ROOT_DIR/scripts/run-ui-tests.sh}"
SCREEN_RECORDING_DISPLAY="${LIVENOTES_UI_RECORDING_DISPLAY:-1}"
SCREEN_RECORDING_RECT="${LIVENOTES_UI_RECORDING_RECT:-}"
SCREEN_RECORDING_WARMUP_SECONDS="${LIVENOTES_UI_RECORDING_WARMUP_SECONDS:-1}"
UI_TEST_SLOT_TIMEOUT_SECONDS="${LIVENOTES_UI_TEST_SLOT_TIMEOUT_SECONDS:-7200}"
UI_TEST_SLOT_POLL_SECONDS="${LIVENOTES_UI_TEST_SLOT_POLL_SECONDS:-15}"
UI_TEST_BLOCKING_PATTERN="${LIVENOTES_UI_TEST_BLOCKING_PATTERN:-DreamCueMac.xcodeproj|DreamCueMacUITests-Runner}"
CONTACT_SHEET_PAGE_SIZE="${LIVENOTES_UI_CONTACT_SHEET_PAGE_SIZE:-9}"
SCREEN_RECORDING_PID=""

mkdir -p "$OUTPUT_DIR"
rm -f "$VIDEO_PATH" "$TIMELINE_VIDEO_PATH" "$SCREENSHOTS_CONTACT_SHEET_PATH"
rm -rf "$ATTACHMENTS_DIR" "$SOURCE_ATTACHMENTS_DIR" "$CONTACT_SHEETS_DIR" "$OUTPUT_DIR/frames"
mkdir -p "$ATTACHMENTS_DIR" "$SOURCE_ATTACHMENTS_DIR"

wait_for_ui_test_slot() {
  local deadline
  deadline=$((SECONDS + UI_TEST_SLOT_TIMEOUT_SECONDS))

  while pgrep -f "$UI_TEST_BLOCKING_PATTERN" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for another UI test run to finish" >&2
      exit 1
    fi
    echo "Waiting for another UI test run to finish before recording LiveNotes UI evidence..."
    sleep "$UI_TEST_SLOT_POLL_SECONDS"
  done
}

start_screen_recording() {
  if ! command -v screencapture >/dev/null 2>&1; then
    echo "screencapture is required to record UI evidence video" >&2
    exit 1
  fi

  if [[ -n "$SCREEN_RECORDING_RECT" ]]; then
    screencapture -v -D "$SCREEN_RECORDING_DISPLAY" -R"$SCREEN_RECORDING_RECT" -x "$VIDEO_PATH" &
  else
    screencapture -v -D "$SCREEN_RECORDING_DISPLAY" -x "$VIDEO_PATH" &
  fi
  SCREEN_RECORDING_PID="$!"
  sleep "$SCREEN_RECORDING_WARMUP_SECONDS"

  if ! kill -0 "$SCREEN_RECORDING_PID" 2>/dev/null; then
    echo "UI evidence video recording did not start" >&2
    exit 1
  fi
}

stop_screen_recording() {
  if [[ -n "$SCREEN_RECORDING_PID" ]] && kill -0 "$SCREEN_RECORDING_PID" 2>/dev/null; then
    kill -INT "$SCREEN_RECORDING_PID" 2>/dev/null || true
    for _ in {1..60}; do
      if ! kill -0 "$SCREEN_RECORDING_PID" 2>/dev/null; then
        wait "$SCREEN_RECORDING_PID" 2>/dev/null || true
        SCREEN_RECORDING_PID=""
        return
      fi
      sleep 0.1
    done
    kill -TERM "$SCREEN_RECORDING_PID" 2>/dev/null || true
    wait "$SCREEN_RECORDING_PID" 2>/dev/null || true
    SCREEN_RECORDING_PID=""
  fi
}

trap stop_screen_recording EXIT
wait_for_ui_test_slot
start_screen_recording

set +e
LIVENOTES_UI_EVIDENCE_DIR="$SOURCE_ATTACHMENTS_DIR" \
  "$RUN_UI_TESTS_BIN" | tee "$LOG_PATH"
TEST_STATUS="${PIPESTATUS[0]}"
set -e

stop_screen_recording

python3 - "$OUTPUT_DIR" "$SOURCE_ATTACHMENTS_DIR" "$CONTACT_SHEET_PAGE_SIZE" <<'PY'
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

output_dir = Path(sys.argv[1])
source_dir = Path(sys.argv[2])
attachments_dir = output_dir / "attachments"
manifest_path = attachments_dir / "manifest.json"
summary_path = output_dir / "summary.json"
frames_dir = output_dir / "frames"
video_path = output_dir / "LiveNotesUITests.mov"
timeline_video_path = output_dir / "LiveNotesUITests-screenshot-timeline.mov"
screenshots_contact_sheet_path = output_dir / "screenshots-contact-sheet.jpg"
contact_sheets_dir = output_dir / "contact-sheets"
page_size = int(sys.argv[3]) if len(sys.argv) > 3 else 9
min_video_seconds = float(os.environ.get("LIVENOTES_UI_MIN_VIDEO_SECONDS", "1"))

items = sorted(source_dir.glob("*.png"))

if not items:
    raise SystemExit("No PNG UI evidence screenshots were written")

if not video_path.exists() or video_path.stat().st_size == 0:
    raise SystemExit(f"UI evidence video was not created at {video_path}")

for source in items:
    shutil.copyfile(source, attachments_dir / source.name)

manifest = [
    {
        "index": index,
        "fileName": source.name,
        "path": str(attachments_dir / source.name),
    }
    for index, source in enumerate(items, start=1)
]
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
summary_path.write_text(
    json.dumps(
        {
            "source": "XCUITest main window screenshots with live screen recording",
            "screenshots": len(items),
            "video": str(video_path),
            "screenshotTimelineVideo": str(timeline_video_path),
            "screenshotsContactSheet": str(screenshots_contact_sheet_path),
            "screenshotsContactSheets": [],
        },
        indent=2,
    ),
    encoding="utf-8",
)

shutil.rmtree(frames_dir, ignore_errors=True)
frames_dir.mkdir(parents=True)
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    raise SystemExit("ffmpeg is required to create UI evidence video")

timeline_frames_dir = frames_dir / "timeline"
timeline_frames_dir.mkdir(parents=True, exist_ok=True)
for index, source in enumerate(items, start=1):
    shutil.copyfile(source, frames_dir / f"frame-{index:04d}.png")
    subprocess.run(
        [
            ffmpeg,
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(source),
            "-vf",
            "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=white",
            "-frames:v",
            "1",
            str(timeline_frames_dir / f"frame-{index:04d}.png"),
        ],
        check=True,
    )

subprocess.run(
    [
        ffmpeg,
        "-y",
        "-loglevel",
        "error",
        "-framerate",
        "1",
        "-start_number",
        "1",
        "-i",
        str(timeline_frames_dir / "frame-%04d.png"),
        "-pix_fmt",
        "yuv420p",
        str(timeline_video_path),
    ],
    check=True,
)

if page_size < 1 or page_size > 9:
    raise SystemExit("Contact sheet page size must be between 1 and 9")

contact_sheets_dir.mkdir(parents=True, exist_ok=True)
contact_sheet_paths = []
for page_index, start in enumerate(range(0, len(items), page_size), start=1):
    chunk = items[start : start + page_size]
    page_frames_dir = frames_dir / f"contact-sheet-{page_index:02d}"
    page_frames_dir.mkdir(parents=True, exist_ok=True)
    for frame_index, source in enumerate(chunk, start=1):
        subprocess.run(
            [
                ffmpeg,
                "-y",
                "-loglevel",
                "error",
                "-i",
                str(source),
                "-vf",
                "scale=480:353:force_original_aspect_ratio=decrease,pad=480:353:(ow-iw)/2:(oh-ih)/2:color=white",
                "-frames:v",
                "1",
                str(page_frames_dir / f"frame-{frame_index:04d}.png"),
            ],
            check=True,
        )
    columns = min(3, len(chunk))
    rows = (len(chunk) + columns - 1) // columns
    contact_sheet_path = contact_sheets_dir / f"screenshots-contact-sheet-{page_index:02d}.jpg"
    subprocess.run(
        [
            ffmpeg,
            "-y",
            "-loglevel",
            "error",
            "-framerate",
            "1",
            "-start_number",
            "1",
            "-i",
            str(page_frames_dir / "frame-%04d.png"),
            "-vf",
            f"tile={columns}x{rows}:color=white",
            "-frames:v",
            "1",
            str(contact_sheet_path),
        ],
        check=True,
    )
    contact_sheet_paths.append(contact_sheet_path)

shutil.copyfile(contact_sheet_paths[0], screenshots_contact_sheet_path)
summary = json.loads(summary_path.read_text(encoding="utf-8"))
summary["screenshotsContactSheet"] = str(contact_sheet_paths[0])
summary["screenshotsContactSheets"] = [str(path) for path in contact_sheet_paths]
summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")

ffprobe = shutil.which("ffprobe")
if ffprobe:
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(video_path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    duration = float(result.stdout.strip())
    if duration < min_video_seconds:
        raise SystemExit("UI evidence video is too short")
PY

if [[ ! -s "$VIDEO_PATH" ]]; then
  echo "UI recording was not created at $VIDEO_PATH" >&2
  exit 1
fi

if [[ ! -s "$TIMELINE_VIDEO_PATH" ]]; then
  echo "UI screenshot timeline video was not created at $TIMELINE_VIDEO_PATH" >&2
  exit 1
fi

if [[ ! -s "$SCREENSHOTS_CONTACT_SHEET_PATH" ]]; then
  echo "UI screenshots contact sheet was not created at $SCREENSHOTS_CONTACT_SHEET_PATH" >&2
  exit 1
fi

exit "$TEST_STATUS"
