#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-e2e-evidence-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT
mkdir -p "$WORK_ROOT/project/scripts" "$WORK_ROOT/bin" "$WORK_ROOT/data"

python3 - "$ROOT_DIR/scripts/run-loopback-e2e-test.sh" "$WORK_ROOT" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
root = Path(sys.argv[2])
(root / "project/scripts/run-loopback-e2e-test.sh").write_text(
    source.replace("/tmp/livenotes-", str(root / "data/livenotes-"))
)
PY

cat > "$WORK_ROOT/bin/say" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
while (( $# )); do
  if [[ "$1" == "-o" ]]; then
    printf 'synthetic speech fixture\n' > "$2"
    exit 0
  fi
  shift
done
exit 1
SCRIPT

cat > "$WORK_ROOT/bin/afconvert" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
cp "${@: -2:1}" "${@: -1}"
SCRIPT

cat > "$WORK_ROOT/bin/xcodebuild" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$LIVENOTES_FAKE_ARGUMENTS_PATH"
result_path=""
while (( $# )); do
  if [[ "$1" == "-resultBundlePath" ]]; then
    result_path="$2"
    break
  fi
  shift
done
[[ -n "$result_path" ]]
mkdir -p "$result_path"
printf 'test results\n' > "$result_path/result.txt"
printf 'native test standard output\n'
printf 'native test standard error\n' >&2
exit "$LIVENOTES_FAKE_TEST_EXIT_STATUS"
SCRIPT
chmod +x "$WORK_ROOT/bin/"*

EVIDENCE_DIR="$WORK_ROOT/project/dist/native-e2e"
mkdir -p "$EVIDENCE_DIR/LiveNotes.xcresult"
touch "$EVIDENCE_DIR/LiveNotes.xcresult/stale.txt"

for expected_status in 65 0; do
  actual_status=0
  PATH="$WORK_ROOT/bin:$PATH" \
  LIVENOTES_FAKE_ARGUMENTS_PATH="$WORK_ROOT/arguments.txt" \
  LIVENOTES_FAKE_TEST_EXIT_STATUS="$expected_status" \
  LIVENOTES_E2E_AUDIO_SOURCE="" \
  LIVENOTES_E2E_EXPECTED_PHRASE="" \
  LIVENOTES_E2E_MODE="audio-file" \
  LIVENOTES_E2E_NATIVE_INFERENCE="true" \
    bash "$WORK_ROOT/project/scripts/run-loopback-e2e-test.sh" > "$WORK_ROOT/run.log" 2>&1 || actual_status=$?
  if [[ "$actual_status" != "$expected_status" ]]; then
    echo "Native audio test must preserve xcodebuild exit status $expected_status; got $actual_status." >&2
    exit 1
  fi
  test -s "$EVIDENCE_DIR/LiveNotes.xcresult/result.txt"
  test ! -e "$EVIDENCE_DIR/LiveNotes.xcresult/stale.txt"
  grep -q 'native test standard output' "$EVIDENCE_DIR/xcodebuild.log"
  grep -q 'native test standard error' "$EVIDENCE_DIR/xcodebuild.log"
  grep -qx 'privacy preserving meeting notes' "$EVIDENCE_DIR/livenotes-e2e-expected-phrase.txt"
  grep -qx 'true' "$EVIDENCE_DIR/livenotes-e2e-native-inference.txt"
  grep -qx 'audio-file' "$EVIDENCE_DIR/livenotes-e2e-mode.txt"
  grep -qx -- '-resultBundlePath' "$WORK_ROOT/arguments.txt"
  cmp "$WORK_ROOT/data/livenotes-e2e-audio-fixture.wav" "$EVIDENCE_DIR/audio-fixture.wav"
  (
    cd "$EVIDENCE_DIR"
    shasum -a 256 -c audio-fixture.wav.sha256 >/dev/null
  )
done

python3 - "$ROOT_DIR" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name in ("ci.yml", "release-homebrew.yml"):
    content = (root / ".github/workflows" / name).read_text()
    match = re.search(r"      - name: Upload native audio test evidence\n(.*?)(?=\n      - name:|\Z)", content, re.S)
    if not match or not all(value in match[1] for value in (
        "if: always()", "actions/upload-artifact@v4", "path: dist/native-e2e"
    )):
        raise SystemExit(f"{name} must retain native audio test evidence after failure.")
PY

printf 'Native audio test evidence checks passed.\n'
