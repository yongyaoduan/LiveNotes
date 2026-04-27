#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-ui-evidence-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

FAKE_BIN="$WORK_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/screencapture" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

OUTPUT_PATH="${@: -1}"
printf "recording\n" > "$OUTPUT_PATH"
trap 'printf "recorded\n" > "$OUTPUT_PATH"; exit 0' INT TERM
while true; do
  sleep 1
done
SCRIPT
chmod +x "$FAKE_BIN/screencapture"

cat > "$FAKE_BIN/ffmpeg" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

OUTPUT_PATH="${@: -1}"
printf "timeline\n" > "$OUTPUT_PATH"
SCRIPT
chmod +x "$FAKE_BIN/ffmpeg"

cat > "$FAKE_BIN/ffprobe" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

printf '3.000000\n'
SCRIPT
chmod +x "$FAKE_BIN/ffprobe"

cat > "$FAKE_BIN/pgrep" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${LIVENOTES_FAKE_DREAMCUE_LOCK:-}" && ! -f "$LIVENOTES_FAKE_DREAMCUE_LOCK" ]]; then
  touch "$LIVENOTES_FAKE_DREAMCUE_LOCK"
  exit 0
fi

exit 1
SCRIPT
chmod +x "$FAKE_BIN/pgrep"

FAKE_RUNNER="$WORK_ROOT/run-ui-tests.sh"
cat > "$FAKE_RUNNER" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

mkdir -p "$LIVENOTES_UI_EVIDENCE_DIR"
python3 - "$LIVENOTES_UI_EVIDENCE_DIR" <<'PY'
import base64
import sys
from pathlib import Path

root = Path(sys.argv[1])
payload = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/luzQ9QAAAABJRU5ErkJggg=="
)
for index, name in enumerate(["home", "live", "saved"], start=1):
    (root / f"{index:02d}-{name}.png").write_bytes(payload)
PY
printf "Test Suite 'All tests' passed\n"
SCRIPT
chmod +x "$FAKE_RUNNER"

OUTPUT_DIR="$WORK_ROOT/evidence"
PATH="$FAKE_BIN:$PATH" \
LIVENOTES_FAKE_DREAMCUE_LOCK="$WORK_ROOT/dreamcue-seen" \
LIVENOTES_UI_EVIDENCE_SOURCE_DIR="$WORK_ROOT/source" \
LIVENOTES_RUN_UI_TESTS_BIN="$FAKE_RUNNER" \
LIVENOTES_UI_RECORDING_RECT="0,0,980,720" \
LIVENOTES_UI_TEST_SLOT_POLL_SECONDS="0.1" \
LIVENOTES_UI_RECORDING_WARMUP_SECONDS="0.1" \
LIVENOTES_UI_CONTACT_SHEET_PAGE_SIZE="2" \
  "$ROOT_DIR/scripts/record-ui-tests.sh" "$OUTPUT_DIR" >"$WORK_ROOT/record-ui-test.log"

if ! grep -q "Waiting for another UI test run to finish" "$WORK_ROOT/record-ui-test.log"; then
  echo "Expected recorder to wait for an active UI test" >&2
  exit 1
fi

if [[ ! -s "$OUTPUT_DIR/LiveNotesUITests.mov" ]]; then
  echo "Expected live screen recording output" >&2
  exit 1
fi

if [[ ! -s "$OUTPUT_DIR/LiveNotesUITests-screenshot-timeline.mov" ]]; then
  echo "Expected screenshot timeline video output" >&2
  exit 1
fi

if [[ ! -s "$OUTPUT_DIR/screenshots-contact-sheet.jpg" ]]; then
  echo "Expected screenshots contact sheet output" >&2
  exit 1
fi

if [[ ! -s "$OUTPUT_DIR/contact-sheets/screenshots-contact-sheet-01.jpg" ]]; then
  echo "Expected first paged screenshots contact sheet output" >&2
  exit 1
fi

if [[ ! -s "$OUTPUT_DIR/contact-sheets/screenshots-contact-sheet-02.jpg" ]]; then
  echo "Expected second paged screenshots contact sheet output" >&2
  exit 1
fi

python3 - "$OUTPUT_DIR" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
summary = json.loads((root / "summary.json").read_text(encoding="utf-8"))
manifest = json.loads((root / "attachments" / "manifest.json").read_text(encoding="utf-8"))

if summary["source"] != "XCUITest main window screenshots with live screen recording":
    raise SystemExit("Unexpected summary source")
if summary["screenshots"] != 3:
    raise SystemExit("Unexpected screenshot count")
if "screenshotTimelineVideo" not in summary:
    raise SystemExit("Missing screenshot timeline path")
if "screenshotsContactSheet" not in summary:
    raise SystemExit("Missing screenshots contact sheet path")
if len(summary.get("screenshotsContactSheets", [])) != 2:
    raise SystemExit("Unexpected paged contact sheet count")
if summary["screenshotsContactSheets"][0] != summary["screenshotsContactSheet"]:
    raise SystemExit("Primary contact sheet should point to the first paged sheet")
if len(manifest) != 3:
    raise SystemExit("Unexpected manifest count")
PY

printf '%s\n' "$OUTPUT_DIR"
