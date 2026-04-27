#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-release-assets-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

LARGE_DMG="$WORK_ROOT/LiveNotes-test.dmg"
printf '0123456789abcdefghijklmnopqrstuvwxyz' > "$LARGE_DMG"

SPLIT_ASSETS="$WORK_ROOT/split-assets"
LIVENOTES_RELEASE_CHUNK_BYTES=10 \
  LIVENOTES_ALLOW_SMALL_RELEASE_CHUNKS=YES \
  "$ROOT_DIR/scripts/package-release-assets.sh" "$LARGE_DMG" "$SPLIT_ASSETS" >/dev/null

if [[ -f "$SPLIT_ASSETS/LiveNotes-test.dmg" ]]; then
  echo "Expected large dmg to be split into release parts" >&2
  exit 1
fi

if [[ ! -x "$SPLIT_ASSETS/restore-LiveNotes-test.dmg.sh" ]]; then
  echo "Expected restore script for split release assets" >&2
  exit 1
fi

PART_COUNT="$(find "$SPLIT_ASSETS" -name 'LiveNotes-test.dmg.part-*' -type f | wc -l | tr -d '[:space:]')"
if (( PART_COUNT < 2 )); then
  echo "Expected at least two split release parts" >&2
  exit 1
fi

RESTORE_DIR="$WORK_ROOT/restore"
mkdir -p "$RESTORE_DIR"
"$SPLIT_ASSETS/restore-LiveNotes-test.dmg.sh" "$RESTORE_DIR/LiveNotes-test.dmg" >/dev/null
cmp "$LARGE_DMG" "$RESTORE_DIR/LiveNotes-test.dmg"

SMALL_DMG="$WORK_ROOT/LiveNotes-small.dmg"
printf 'small' > "$SMALL_DMG"

FULL_ASSETS="$WORK_ROOT/full-assets"
LIVENOTES_RELEASE_CHUNK_BYTES=1048576 \
  "$ROOT_DIR/scripts/package-release-assets.sh" "$SMALL_DMG" "$FULL_ASSETS" >/dev/null

if [[ ! -f "$FULL_ASSETS/LiveNotes-small.dmg" ]]; then
  echo "Expected small dmg to be copied as one release asset" >&2
  exit 1
fi

if find "$FULL_ASSETS" -name 'LiveNotes-small.dmg.part-*' -type f | grep -q .; then
  echo "Did not expect split parts for small dmg" >&2
  exit 1
fi

if [[ ! -f "$FULL_ASSETS/LiveNotes-small.dmg.sha256" ]]; then
  echo "Expected checksum for small release asset" >&2
  exit 1
fi

ANCESTOR_ROOT="$WORK_ROOT/ancestor-case"
mkdir -p "$ANCESTOR_ROOT/source"
ANCESTOR_DMG="$ANCESTOR_ROOT/source/LiveNotes-ancestor.dmg"
printf 'ancestor' > "$ANCESTOR_DMG"

if "$ROOT_DIR/scripts/package-release-assets.sh" "$ANCESTOR_DMG" "$ANCESTOR_ROOT" >/dev/null 2>"$WORK_ROOT/ancestor-error.log"; then
  echo "Expected ancestor asset directory to be rejected" >&2
  exit 1
fi

if [[ ! -f "$ANCESTOR_DMG" ]]; then
  echo "Source dmg was removed after rejected ancestor asset directory" >&2
  exit 1
fi

if ! grep -q "must not contain the source dmg" "$WORK_ROOT/ancestor-error.log"; then
  echo "Expected ancestor rejection message" >&2
  exit 1
fi

printf '%s\n' "$SPLIT_ASSETS"
