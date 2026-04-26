#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${1:-}"
ASSET_DIR="${2:-$ROOT_DIR/dist/release-assets}"
CHUNK_BYTES="${LIVENOTES_RELEASE_CHUNK_BYTES:-1900000000}"

if [[ -z "$DMG_PATH" ]]; then
  echo "Usage: package-release-assets.sh <dmg-path> [asset-dir]" >&2
  exit 64
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Release dmg does not exist: $DMG_PATH" >&2
  exit 66
fi

DMG_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
ASSET_PARENT="$(dirname "$ASSET_DIR")"
mkdir -p "$ASSET_PARENT"
ASSET_DIR="$(cd "$ASSET_PARENT" && pwd)/$(basename "$ASSET_DIR")"

if [[ "$ASSET_DIR" == "/" || "$ASSET_DIR" == "$DMG_DIR" ]]; then
  echo "Release asset directory must be separate from the dmg directory" >&2
  exit 64
fi

case "$CHUNK_BYTES" in
  ''|*[!0-9]*)
    echo "LIVENOTES_RELEASE_CHUNK_BYTES must be a positive integer" >&2
    exit 64
    ;;
esac

if (( CHUNK_BYTES < 1048576 )); then
  if [[ "${LIVENOTES_ALLOW_SMALL_RELEASE_CHUNKS:-NO}" != "YES" ]]; then
    echo "Release chunk size must be at least 1048576 bytes" >&2
    exit 64
  fi
fi

mkdir -p "$ASSET_DIR"
rm -rf "$ASSET_DIR"
mkdir -p "$ASSET_DIR"

DMG_BASENAME="$(basename "$DMG_PATH")"
DMG_SIZE="$(wc -c < "$DMG_PATH" | tr -d '[:space:]')"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

printf '%s  %s\n' "$DMG_SHA256" "$DMG_BASENAME" > "$ASSET_DIR/$DMG_BASENAME.sha256"

if (( DMG_SIZE <= CHUNK_BYTES )); then
  cp "$DMG_PATH" "$ASSET_DIR/$DMG_BASENAME"
else
  split -b "$CHUNK_BYTES" "$DMG_PATH" "$ASSET_DIR/$DMG_BASENAME.part-"
  RESTORE_SCRIPT="$ASSET_DIR/restore-$DMG_BASENAME.sh"
  cat > "$RESTORE_SCRIPT" <<SCRIPT
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PATH="\${1:-$DMG_BASENAME}"
OUTPUT_DIR="\$(dirname "\$OUTPUT_PATH")"
OUTPUT_NAME="\$(basename "\$OUTPUT_PATH")"
PART_PREFIX="\$SCRIPT_DIR/$DMG_BASENAME.part-"
FIRST_PART="\$SCRIPT_DIR/$DMG_BASENAME.part-aa"
TMP_PATH="\$OUTPUT_PATH.tmp"

if [[ ! -f "\$FIRST_PART" ]]; then
  echo "Missing release parts for $DMG_BASENAME" >&2
  exit 66
fi

mkdir -p "\$OUTPUT_DIR"
rm -f "\$TMP_PATH"
for part in "\$PART_PREFIX"*; do
  cat "\$part" >> "\$TMP_PATH"
done
mv "\$TMP_PATH" "\$OUTPUT_PATH"

(
  cd "\$OUTPUT_DIR"
  printf '%s  %s\n' "$DMG_SHA256" "\$OUTPUT_NAME" | shasum -a 256 -c -
)

printf '%s\n' "\$OUTPUT_PATH"
SCRIPT
  chmod +x "$RESTORE_SCRIPT"
fi

printf '%s\n' "$ASSET_DIR"
