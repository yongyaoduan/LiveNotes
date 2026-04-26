#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/model-artifacts.sh"

WORK_ROOT="$(mktemp -d /tmp/livenotes-dmg-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

EMPTY_ARTIFACTS="$WORK_ROOT/empty-artifacts"
mkdir -p "$EMPTY_ARTIFACTS"

if LIVENOTES_BUNDLED_ARTIFACT_SOURCE_ROOT="$EMPTY_ARTIFACTS" \
  LIVENOTES_PREBUILT_APP_SOURCE="$WORK_ROOT/Missing.app" \
  "$ROOT_DIR/scripts/build-dmg.sh" >/tmp/livenotes-empty-dmg-test.log 2>&1; then
  echo "Expected build-dmg.sh to fail when model artifacts are missing" >&2
  exit 1
fi

FIXTURE_ARTIFACTS="$WORK_ROOT/artifacts"
for relative_path in "${REQUIRED_ARTIFACT_PATHS[@]}"; do
  output_path="$FIXTURE_ARTIFACTS/$relative_path"
  mkdir -p "$(dirname "$output_path")"
  printf 'fixture\n' > "$output_path"
done

PREBUILT_APP="$WORK_ROOT/LiveNotes.app"
mkdir -p "$PREBUILT_APP/Contents/MacOS" "$PREBUILT_APP/Contents/Resources"
cat > "$PREBUILT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>LiveNotes</string>
  <key>CFBundleIdentifier</key>
  <string>app.livenotes.mac</string>
  <key>CFBundleName</key>
  <string>LiveNotes</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
PLIST
printf '#!/usr/bin/env bash\nexit 0\n' > "$PREBUILT_APP/Contents/MacOS/LiveNotes"
chmod +x "$PREBUILT_APP/Contents/MacOS/LiveNotes"

DMG_PATH="$(
  LIVENOTES_BUNDLED_ARTIFACT_SOURCE_ROOT="$FIXTURE_ARTIFACTS" \
  LIVENOTES_PREBUILT_APP_SOURCE="$PREBUILT_APP" \
  LIVENOTES_RELEASE_NAME="LiveNotes-script-test" \
  DERIVED_DATA_PATH="$WORK_ROOT/DerivedData" \
  "$ROOT_DIR/scripts/build-dmg.sh"
)"

if [[ ! -s "$DMG_PATH" ]]; then
  echo "Expected dmg at $DMG_PATH" >&2
  exit 1
fi

printf '%s\n' "$DMG_PATH"
