#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/model-artifacts.sh"

VERSION="${1:-}"
ZIP_URL="${2:-}"
SHA256="${3:-}"
OUTPUT_PATH="${4:-$ROOT_DIR/dist/homebrew/Casks/livenotes.rb}"
RUNTIME_REQUIREMENTS_PATH="${LIVENOTES_RUNTIME_REQUIREMENTS_PATH:-$ROOT_DIR/scripts/runtime-requirements.txt}"

if [[ -z "$VERSION" || -z "$ZIP_URL" || -z "$SHA256" ]]; then
  echo "Usage: write-homebrew-cask.sh <version> <zip-url> <sha256> [output-path]" >&2
  exit 64
fi

if [[ ! -f "$RUNTIME_REQUIREMENTS_PATH" ]]; then
  echo "Runtime requirements file does not exist: $RUNTIME_REQUIREMENTS_PATH" >&2
  exit 66
fi

RUNTIME_REQUIREMENTS=()
while IFS= read -r requirement || [[ -n "$requirement" ]]; do
  [[ -z "$requirement" ]] && continue
  [[ "$requirement" == \#* ]] && continue
  RUNTIME_REQUIREMENTS+=("$requirement")
done < "$RUNTIME_REQUIREMENTS_PATH"

if (( ${#RUNTIME_REQUIREMENTS[@]} == 0 )); then
  echo "Runtime requirements file is empty: $RUNTIME_REQUIREMENTS_PATH" >&2
  exit 66
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

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"
  depends_on formula: "python@3.12"

  app "LiveNotes.app"

  postflight do
    require "digest"

    support_root = ENV.fetch("LIVENOTES_SUPPORT_ROOT", File.expand_path("~/Library/Application Support/LiveNotes"))
    artifact_root = File.join(support_root, "LiveNotesArtifacts")
    runtime_root = File.join(support_root, "Runtime")
    runtime_python = File.join(runtime_root, "bin/python3")
    homebrew_prefix = ENV.fetch("HOMEBREW_PREFIX", "/opt/homebrew")
    python_candidates = [
      "#{homebrew_prefix}/bin/python3.12",
      "/opt/homebrew/bin/python3.12",
      "/usr/local/bin/python3.12",
    ].select { |path| File.executable?(path) }
    raise "Python 3.12 is required to install the LiveNotes local runtime" if python_candidates.empty?
    runtime_packages = [
CASK

  for requirement in "${RUNTIME_REQUIREMENTS[@]}"; do
    printf '      "%s",\n' "$requirement"
  done

  cat <<'CASK'
    ]

    unless File.executable?(runtime_python)
      system_command "/bin/rm", args: ["-rf", runtime_root]
      system_command python_candidates.first, args: ["-m", "venv", runtime_root]
    end
    system_command runtime_python,
                   args: ["-m", "pip", "install", "--upgrade"] + runtime_packages

    artifacts = [
CASK

  for entry in "${REMOTE_ARTIFACTS[@]}"; do
    IFS='|' read -r remote_url relative_path expected_size expected_sha <<< "$entry"
    printf '      ["%s", "%s", %s, "%s"],\n' "$remote_url" "$relative_path" "$expected_size" "$expected_sha"
  done

  cat <<'CASK'
    ]

    artifacts.each do |remote_url, relative_path, expected_size, expected_sha|
      output_path = File.join(artifact_root, relative_path)
      if File.exist?(output_path) && File.size(output_path) == expected_size
        next if expected_sha.empty? || Digest::SHA256.file(output_path).hexdigest == expected_sha
      end

      system_command "/bin/mkdir", args: ["-p", File.dirname(output_path)]
      temporary_path = "#{output_path}.download"
      curl_bin = ENV.fetch("LIVENOTES_CURL_BIN", "/usr/bin/curl")
      system_command curl_bin,
                     args: [
                       "--fail",
                       "--location",
                       "--retry", "5",
                       "--retry-delay", "5",
                       "--continue-at", "-",
                       "--output", temporary_path,
                       remote_url,
                     ]
      if File.size(temporary_path) != expected_size
        raise "Downloaded #{relative_path} has size #{File.size(temporary_path)}, expected #{expected_size}"
      end
      if !expected_sha.empty? && Digest::SHA256.file(temporary_path).hexdigest != expected_sha
        raise "Downloaded #{relative_path} failed sha256 verification"
      end
      File.rename(temporary_path, output_path)
    end
  end

  uninstall_postflight do
    require "fileutils"

    support_root = ENV.fetch("LIVENOTES_SUPPORT_ROOT", File.expand_path("~/Library/Application Support/LiveNotes"))
    [
      File.join(support_root, "LiveNotesArtifacts"),
      File.join(support_root, "Runtime"),
      File.expand_path("~/Library/Preferences/app.livenotes.mac.plist"),
    ].each { |path| FileUtils.rm_rf(path) }
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
