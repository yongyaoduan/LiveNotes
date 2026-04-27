#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_SECONDS="${LIVENOTES_UI_TEST_TIMEOUT_SECONDS:-600}"

python3 - "$ROOT_DIR" "$TIMEOUT_SECONDS" <<'PY'
import re
import selectors
import subprocess
import sys
import time

root_dir = sys.argv[1]
timeout_seconds = int(sys.argv[2])

command = [
    "xcodebuild",
    "test",
    "-project", "LiveNotes.xcodeproj",
    "-scheme", "LiveNotes",
    "-destination", "platform=macOS,arch=arm64",
]

process = subprocess.Popen(
    command,
    cwd=root_dir,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)

selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
deadline = time.monotonic() + timeout_seconds
finalization_deadline = None
saw_passing_suite = False
saw_failure = False

failure_pattern = re.compile(r"(Test Suite '.+' failed|Test Case '.+' failed|: error:)")
passing_pattern = re.compile(r"Test Suite '(All tests|Selected tests)' passed")

while True:
    events = selector.select(timeout=0.2)
    for key, _ in events:
        line = key.fileobj.readline()
        if not line:
            continue
        print(line, end="", flush=True)
        if passing_pattern.search(line):
            saw_passing_suite = True
            finalization_deadline = time.monotonic() + 20
        if failure_pattern.search(line):
            saw_failure = True

    return_code = process.poll()
    if return_code is not None:
        for line in process.stdout:
            print(line, end="", flush=True)
            if passing_pattern.search(line):
                saw_passing_suite = True
            if failure_pattern.search(line):
                saw_failure = True
        if return_code != 0:
            sys.exit(return_code)
        if not saw_passing_suite:
            print("UI test output did not include a passing test suite.", file=sys.stderr, flush=True)
            sys.exit(1)
        if saw_failure:
            print("UI test output included a failure.", file=sys.stderr, flush=True)
            sys.exit(1)
        sys.exit(0)

    if finalization_deadline and time.monotonic() > finalization_deadline:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if saw_failure:
            print("UI test output included a failure.", file=sys.stderr, flush=True)
            sys.exit(1)
        print("UI tests passed; xcodebuild did not exit after log finalization.", file=sys.stderr, flush=True)
        sys.exit(0)

    if time.monotonic() > deadline:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        print("UI tests timed out", file=sys.stderr, flush=True)
        if saw_passing_suite and not saw_failure:
            sys.exit(0)
        sys.exit(1)

    time.sleep(0.05)

if saw_failure:
    print("UI test output included a failure.", file=sys.stderr, flush=True)
    sys.exit(1)
PY
