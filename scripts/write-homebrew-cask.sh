#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/model-artifacts.sh"

VERSION="${1:-}"
ZIP_URL="${2:-}"
SHA256="${3:-}"
OUTPUT_PATH="${4:-$ROOT_DIR/dist/homebrew/Casks/livenotes.rb}"

if [[ -z "$VERSION" || -z "$ZIP_URL" || -z "$SHA256" ]]; then
  echo "Usage: write-homebrew-cask.sh <version> <zip-url> <sha256> [output-path]" >&2
  exit 64
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

{
  cat <<CASK
cask "livenotes" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$ZIP_URL"
  name "LiveNotes"
  desc "Local live recording, transcription, translation, and topic notes"
  homepage "https://github.com/yongyaoduan/LiveNotes"

  depends_on macos: ">= :sonoma"

  app "LiveNotes.app"

  postflight do
    artifact_root = File.expand_path("~/Library/Application Support/LiveNotes/LiveNotesArtifacts")
    artifacts = [
CASK

  for entry in "${REMOTE_ARTIFACTS[@]}"; do
    remote_url="${entry%%|*}"
    relative_path="${entry#*|}"
    printf '      ["%s", "%s"],\n' "$remote_url" "$relative_path"
  done

  cat <<'CASK'
    ]

    artifacts.each do |remote_url, relative_path|
      output_path = File.join(artifact_root, relative_path)
      next if File.exist?(output_path) && File.size(output_path).positive?

      system_command "/bin/mkdir", args: ["-p", File.dirname(output_path)]
      system_command "/usr/bin/curl",
                     args: [
                       "--fail",
                       "--location",
                       "--retry", "5",
                       "--retry-delay", "5",
                       "--continue-at", "-",
                       "--output", output_path,
                       remote_url,
                     ]
    end
  end

  uninstall quit: "app.livenotes.mac"

  zap trash: [
    "~/Library/Application Support/LiveNotes",
    "~/Library/Preferences/app.livenotes.mac.plist",
  ]
end
CASK
} > "$OUTPUT_PATH"

printf '%s\n' "$OUTPUT_PATH"
