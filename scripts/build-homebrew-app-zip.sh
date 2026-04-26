#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/LiveNotes.xcodeproj"
SCHEME_NAME="LiveNotes"
APP_NAME="LiveNotes"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/livenotes-homebrew}"
DIST_DIR="$ROOT_DIR/dist"
BUILD_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"

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

ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
  build

if [[ ! -d "$BUILD_APP_PATH" ]]; then
  echo "Release app was not built at $BUILD_APP_PATH" >&2
  exit 1
fi

ditto -c -k --keepParent "$BUILD_APP_PATH" "$ZIP_PATH"

printf '%s\n' "$ZIP_PATH"
