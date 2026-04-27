#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/model-artifacts.sh"

WORK_ROOT="$(mktemp -d /tmp/livenotes-dmg-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

FIXTURE_LOCK="$WORK_ROOT/fixture-lock.json"
export LIVENOTES_MODEL_ARTIFACT_LOCK="$FIXTURE_LOCK"

EMPTY_ARTIFACTS="$WORK_ROOT/empty-artifacts"
mkdir -p "$EMPTY_ARTIFACTS"

if LIVENOTES_BUNDLED_ARTIFACT_SOURCE_ROOT="$EMPTY_ARTIFACTS" \
  LIVENOTES_PREBUILT_APP_SOURCE="$WORK_ROOT/Missing.app" \
  "$ROOT_DIR/scripts/build-dmg.sh" >/tmp/livenotes-empty-dmg-test.log 2>&1; then
  echo "Expected build-dmg.sh to fail when model artifacts are missing" >&2
  exit 1
fi

FIXTURE_ARTIFACTS="$WORK_ROOT/artifacts"
python - "$FIXTURE_ARTIFACTS" "$FIXTURE_LOCK" "${REQUIRED_ARTIFACT_PATHS[@]}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
lock_path = Path(sys.argv[2])
paths = sys.argv[3:]
artifacts = []

for relative_path in paths:
    path = root / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    if relative_path.endswith("model.safetensors.index.json"):
        shard = "model.safetensors"
        data = json.dumps({"weight_map": {"layer": shard}}).encode()
        kind = "safetensors_index"
    elif relative_path.endswith(".json"):
        data = json.dumps({"fixture": relative_path}).encode()
        kind = "json"
    else:
        data = b"fixture\n"
        kind = "text"
    path.write_bytes(data)
    artifacts.append({
        "path": relative_path,
        "size": len(data),
        "type": kind,
    })

lock = {
    "schema": 1,
    "default_profile": {
        "runtime": "mlx",
        "transcription": "fixture",
        "summarization": "fixture",
        "translation": "fixture",
    },
    "models": [
        {
            "id": "fixture",
            "tasks": ["transcription", "summarization", "translation"],
            "bundled": True,
            "artifacts": artifacts,
        }
    ],
}
lock_path.write_text(json.dumps(lock), encoding="utf-8")
PY

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
