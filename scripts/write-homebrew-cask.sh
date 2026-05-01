#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${1:-}"
ZIP_URL="${2:-}"
SHA256="${3:-}"
OUTPUT_PATH="${4:-$ROOT_DIR/dist/homebrew/Casks/livenotes.rb}"

if [[ -z "$VERSION" || -z "$ZIP_URL" || -z "$SHA256" ]]; then
  echo "Usage: write-homebrew-cask.sh <version> <zip-url> <sha256> [output-path]" >&2
  exit 64
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

cat > "$OUTPUT_PATH" <<CASK
cask "livenotes" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$ZIP_URL"
  name "LiveNotes"
  desc "Local live recording, transcription, translation, and saved transcripts"
  homepage "https://github.com/yongyaoduan/LiveNotes"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "LiveNotes.app"

  caveats <<~EOS
    Preview builds are not Developer ID signed or notarized until Apple Developer Program credentials are configured.
    If macOS blocks launch, open System Settings > Privacy & Security and choose Open Anyway.
  EOS

  uninstall quit:   "app.livenotes.mac",
            delete: [
              "~/Library/Application Support/LiveNotes/LiveNotesArtifacts",
              "~/Library/Application Support/LiveNotes/Runtime",
            ],
            trash:  "~/Library/Preferences/app.livenotes.mac.plist"

  zap trash: [
    "~/Library/Application Support/LiveNotes",
    "~/Library/Preferences/app.livenotes.mac.plist",
  ]
end
CASK

printf '%s\n' "$OUTPUT_PATH"
