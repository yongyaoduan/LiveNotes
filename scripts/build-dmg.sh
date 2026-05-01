#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_PATH="$ROOT_DIR/LiveNotes.xcodeproj"
SCHEME_NAME="LiveNotes"
APP_NAME="LiveNotes"
VOLNAME="LiveNotes"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/livenotes-release}"
DIST_DIR="$ROOT_DIR/dist"
BUILD_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
APPICONSET_PATH="$ROOT_DIR/LiveNotesApp/Assets.xcassets/AppIcon.appiconset"
PREBUILT_APP_SOURCE="${LIVENOTES_PREBUILT_APP_SOURCE:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RELEASE_NAME="${LIVENOTES_RELEASE_NAME:-}"
if [[ -n "$RELEASE_NAME" ]]; then
  DMG_PATH="$DIST_DIR/$RELEASE_NAME.dmg"
else
  DMG_PATH="$DIST_DIR/$APP_NAME-$STAMP.dmg"
fi
LATEST_PATH="$DIST_DIR/$APP_NAME-latest.dmg"

create_volume_icon() {
  local iconset_root="$1"
  local icns_path="$2"

  mkdir -p "$iconset_root"
  cp "$APPICONSET_PATH/icon_16.png" "$iconset_root/icon_16x16.png"
  cp "$APPICONSET_PATH/icon_32.png" "$iconset_root/icon_16x16@2x.png"
  cp "$APPICONSET_PATH/icon_32.png" "$iconset_root/icon_32x32.png"
  cp "$APPICONSET_PATH/icon_64.png" "$iconset_root/icon_32x32@2x.png"
  cp "$APPICONSET_PATH/icon_128.png" "$iconset_root/icon_128x128.png"
  cp "$APPICONSET_PATH/icon_256.png" "$iconset_root/icon_128x128@2x.png"
  cp "$APPICONSET_PATH/icon_256.png" "$iconset_root/icon_256x256.png"
  cp "$APPICONSET_PATH/icon_512.png" "$iconset_root/icon_256x256@2x.png"
  cp "$APPICONSET_PATH/icon_512.png" "$iconset_root/icon_512x512.png"
  cp "$APPICONSET_PATH/icon_1024.png" "$iconset_root/icon_512x512@2x.png"
  iconutil -c icns "$iconset_root" -o "$icns_path"
}

mkdir -p "$DIST_DIR"

if [[ -n "$PREBUILT_APP_SOURCE" ]]; then
  rm -rf "$BUILD_APP_PATH"
  mkdir -p "$(dirname "$BUILD_APP_PATH")"
  ditto "$PREBUILT_APP_SOURCE" "$BUILD_APP_PATH"
else
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    build
fi

if [[ ! -d "$BUILD_APP_PATH" ]]; then
  echo "Release app was not built at $BUILD_APP_PATH" >&2
    exit 1
fi

WORK_ROOT="$(mktemp -d /tmp/livenotes-dmg.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

STAGING_ROOT="$WORK_ROOT/$VOLNAME"
ICONSET_ROOT="$WORK_ROOT/VolumeIcon.iconset"
ICNS_PATH="$WORK_ROOT/.VolumeIcon.icns"

mkdir -p "$STAGING_ROOT"
ditto "$BUILD_APP_PATH" "$STAGING_ROOT/$APP_NAME.app"
ln -s /Applications "$STAGING_ROOT/Applications"
create_volume_icon "$ICONSET_ROOT" "$ICNS_PATH"
cp "$ICNS_PATH" "$STAGING_ROOT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$STAGING_ROOT"
fi

hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -f "$LATEST_PATH"
ln -s "$(basename "$DMG_PATH")" "$LATEST_PATH"

printf '%s\n' "$DMG_PATH"
