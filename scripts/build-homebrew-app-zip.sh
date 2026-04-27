#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/LiveNotes.xcodeproj"
SCHEME_NAME="LiveNotes"
APP_NAME="LiveNotes"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/livenotes-homebrew}"
DIST_DIR="$ROOT_DIR/dist"
BUILD_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
SIGNING_IDENTITY="${LIVENOTES_DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application}"

read_project_version() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -showBuildSettings 2>/dev/null |
    awk -F= '/ MARKETING_VERSION / { gsub(/[[:space:]]/, "", $2); print $2; exit }'
}

VERSION="${LIVENOTES_RELEASE_VERSION:-$(read_project_version)}"
if [[ -z "$VERSION" ]]; then
  echo "Unable to determine release version" >&2
  exit 65
fi

if [[ "${LIVENOTES_NOTARIZE_APP:-0}" == "1" && "${LIVENOTES_REQUIRE_SIGNED_APP:-0}" != "1" ]]; then
  echo "Notarization requires Developer ID signing" >&2
  exit 65
fi

ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
if [[ "${LIVENOTES_REQUIRE_SIGNED_APP:-0}" == "1" ]]; then
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
else
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
fi

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
  build

if [[ ! -d "$BUILD_APP_PATH" ]]; then
  echo "Release app was not built at $BUILD_APP_PATH" >&2
  exit 1
fi

if [[ "${LIVENOTES_REQUIRE_SIGNED_APP:-0}" == "1" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BUILD_APP_PATH"
  codesign --verify --strict --deep "$BUILD_APP_PATH"
  signature_details="$(codesign -dv --verbose=4 "$BUILD_APP_PATH" 2>&1 || true)"
  if ! grep -q 'Authority=Developer ID Application' <<<"$signature_details"; then
    echo "Release app must be signed with a Developer ID Application certificate" >&2
    exit 1
  fi
fi

if [[ "${LIVENOTES_NOTARIZE_APP:-0}" == "1" ]]; then
  : "${APPLE_ID:?APPLE_ID is required for notarization}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for notarization}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required for notarization}"
  notarization_zip="$DIST_DIR/$APP_NAME-$VERSION-notarization.zip"
  rm -f "$notarization_zip"
  ditto -c -k --keepParent "$BUILD_APP_PATH" "$notarization_zip"
  xcrun notarytool submit "$notarization_zip" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$BUILD_APP_PATH"
  xcrun stapler validate "$BUILD_APP_PATH"
  spctl --assess --type execute --verbose=4 "$BUILD_APP_PATH"
  rm -f "$notarization_zip"
fi

ditto -c -k --keepParent "$BUILD_APP_PATH" "$ZIP_PATH"

printf '%s\n' "$ZIP_PATH"
