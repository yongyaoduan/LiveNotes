#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-artifact-prepare-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

FAKE_CURL="$WORK_ROOT/fake-curl.sh"
cat > "$FAKE_CURL" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

OUTPUT_PATH=""
while (( $# > 0 )); do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$OUTPUT_PATH" ]]; then
  echo "Missing curl output path" >&2
  exit 64
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
printf 'fixture\n' > "$OUTPUT_PATH"
SCRIPT
chmod +x "$FAKE_CURL"

python - "$ROOT_DIR/QualityBenchmarks/model-artifacts.lock.json" "$WORK_ROOT/fixture-lock.json" <<'PY'
import hashlib
import json
import sys

source_path, output_path = sys.argv[1:3]
with open(source_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

for model in payload["models"]:
    if not model.get("bundled", False):
        continue
    model.pop("precision", None)
    for artifact in model["artifacts"]:
        artifact["size"] = 8
        artifact["sha256"] = hashlib.sha256(b"fixture\n").hexdigest()
        artifact["type"] = "text"

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

mkdir -p "$WORK_ROOT/artifacts/models/whisper-large-v3-turbo"
printf 'corrupt\n' > "$WORK_ROOT/artifacts/models/whisper-large-v3-turbo/config.json"

unset HF_TOKEN
LIVENOTES_MODEL_ARTIFACT_LOCK="$WORK_ROOT/fixture-lock.json" \
LIVENOTES_CURL_BIN="$FAKE_CURL" \
  "$ROOT_DIR/scripts/prepare-bundled-artifacts.sh" "$WORK_ROOT/artifacts" >/dev/null

if [[ ! -s "$WORK_ROOT/artifacts/models/whisper-large-v3-turbo/config.json" ]]; then
  echo "Expected prepared artifact fixture" >&2
  exit 1
fi
if [[ "$(cat "$WORK_ROOT/artifacts/models/whisper-large-v3-turbo/config.json")" != "fixture" ]]; then
  echo "Expected corrupt same-size artifact to be replaced" >&2
  exit 1
fi

printf '%s\n' "$WORK_ROOT/artifacts"
