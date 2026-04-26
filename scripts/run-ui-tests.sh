#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_SECONDS="${LIVENOTES_UI_TEST_TIMEOUT_SECONDS:-600}"

python3 - "$ROOT_DIR" "$TIMEOUT_SECONDS" <<'PY'
import os
import shutil
import subprocess
import sys
import time

root_dir = sys.argv[1]
timeout_seconds = int(sys.argv[2])
result_bundle_path = os.environ.get(
    "LIVENOTES_UI_RESULT_BUNDLE_PATH",
    os.path.join(root_dir, "dist", "LiveNotesUITests.xcresult"),
)
os.makedirs(os.path.dirname(result_bundle_path), exist_ok=True)
if os.path.exists(result_bundle_path):
    shutil.rmtree(result_bundle_path)

command = [
    "xcodebuild",
    "test",
    "-project", "LiveNotes.xcodeproj",
    "-scheme", "LiveNotes",
    "-destination", "platform=macOS,arch=arm64",
    "-resultBundlePath", result_bundle_path,
]

process = subprocess.Popen(
    command,
    cwd=root_dir,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
)

start = time.monotonic()
saw_pass = False
saw_failure = False

assert process.stdout is not None
while True:
    line = process.stdout.readline()
    if line:
        print(line, end="", flush=True)
        if "Test Suite 'All tests' passed" in line or "Test Suite 'Selected tests' passed" in line or "** TEST SUCCEEDED **" in line:
            saw_pass = True
        if "failed at" in line or ": error: -" in line or "** TEST FAILED **" in line or "XCTAssert" in line:
            saw_failure = True
    else:
        exit_code = process.poll()
        if exit_code is not None:
            sys.exit(exit_code)
        time.sleep(0.1)

    if saw_failure:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        sys.exit(1)

    if saw_pass:
        try:
            exit_code = process.wait(timeout=5)
            sys.exit(exit_code)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
            sys.exit(0)

    if time.monotonic() - start > timeout_seconds:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        print("UI tests timed out", file=sys.stderr)
        sys.exit(1)
PY
