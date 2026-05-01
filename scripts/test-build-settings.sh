#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

debug_settings="$(
  xcodebuild -showBuildSettings \
    -project "$ROOT_DIR/LiveNotes.xcodeproj" \
    -configuration Debug \
    -target LiveNotes 2>/dev/null
)"

release_settings="$(
  xcodebuild -showBuildSettings \
    -project "$ROOT_DIR/LiveNotes.xcodeproj" \
    -configuration Release \
    -target LiveNotes 2>/dev/null
)"

if ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER = app.livenotes.mac.debug' <<<"$debug_settings"; then
  echo "Debug builds must use app.livenotes.mac.debug to isolate UI-test microphone permissions." >&2
  exit 1
fi

if ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER = app.livenotes.mac$' <<<"$release_settings"; then
  echo "Release builds must use app.livenotes.mac for Homebrew and user data compatibility." >&2
  exit 1
fi

if grep -q 'PRODUCT_BUNDLE_IDENTIFIER = app.livenotes.mac$' <<<"$debug_settings"; then
  echo "Debug builds must not share the production microphone permission identity." >&2
  exit 1
fi

if ! grep -q 'CODE_SIGN_ENTITLEMENTS = LiveNotesApp/LiveNotes.entitlements' <<<"$release_settings"; then
  echo "Release builds must include the LiveNotes entitlements file." >&2
  exit 1
fi

if ! grep -q 'CODE_SIGN_ENTITLEMENTS = LiveNotesApp/LiveNotes.entitlements' <<<"$debug_settings"; then
  echo "Debug builds must include the LiveNotes entitlements file." >&2
  exit 1
fi
