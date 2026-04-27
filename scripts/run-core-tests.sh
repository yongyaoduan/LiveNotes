#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/LiveNotesCore"
TEST_LIST_PATH="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/livenotes-core-tests.txt"

cd "$PACKAGE_DIR"

swift --version

echo "Listing LiveNotesCore tests at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
swift test --disable-sandbox --disable-xctest list |
  awk '/^LiveNotesCoreTests\./ { print }' > "$TEST_LIST_PATH"

test_count="$(wc -l < "$TEST_LIST_PATH" | tr -d '[:space:]')"
if [[ "$test_count" == "0" ]]; then
  echo "No LiveNotesCore tests were found." >&2
  exit 65
fi

echo "Found $test_count LiveNotesCore tests."

test_index=0
while IFS= read -r test_name; do
  test_index=$((test_index + 1))
  started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  started_seconds="$(date +%s)"
  echo "Starting LiveNotesCore test $test_index/$test_count at $started_at: $test_name"
  if swift test --disable-sandbox --disable-xctest --skip-build --filter "$test_name"; then
    finished_seconds="$(date +%s)"
    duration_seconds=$((finished_seconds - started_seconds))
    echo "Finished LiveNotesCore test $test_index/$test_count in ${duration_seconds}s: $test_name"
  else
    finished_seconds="$(date +%s)"
    duration_seconds=$((finished_seconds - started_seconds))
    echo "Failed LiveNotesCore test $test_index/$test_count after ${duration_seconds}s: $test_name" >&2
    exit 1
  fi
done < "$TEST_LIST_PATH"

echo "All LiveNotesCore tests passed."
