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

unset HF_TOKEN
LIVENOTES_CURL_BIN="$FAKE_CURL" \
  "$ROOT_DIR/scripts/prepare-bundled-artifacts.sh" "$WORK_ROOT/artifacts" >/dev/null

if [[ ! -s "$WORK_ROOT/artifacts/models/whisper-medium/config.json" ]]; then
  echo "Expected prepared artifact fixture" >&2
  exit 1
fi

printf '%s\n' "$WORK_ROOT/artifacts"
