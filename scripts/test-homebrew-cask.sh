#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-homebrew-cask-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

CASK_PATH="$WORK_ROOT/livenotes.rb"
WORKFLOW_PATH="$ROOT_DIR/.github/workflows/release-homebrew.yml"
CI_WORKFLOW_PATH="$ROOT_DIR/.github/workflows/ci.yml"
APP_MODEL_PATH="$ROOT_DIR/LiveNotesApp/AppModel.swift"
"$ROOT_DIR/scripts/write-homebrew-cask.sh" \
  "0.1.0" \
  "https://github.com/yongyaoduan/LiveNotes/releases/download/v0.1.0/LiveNotes-0.1.0.zip" \
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  "$CASK_PATH" >/dev/null

ruby -c "$CASK_PATH" >/dev/null

grep -q 'cask "livenotes"' "$CASK_PATH"
grep -q 'LiveNotesArtifacts' "$CASK_PATH"
grep -q 'Runtime' "$CASK_PATH"
grep -q 'python@3.12' "$CASK_PATH"
grep -q 'mlx==0.31.1' "$CASK_PATH"
grep -q 'mlx-whisper==0.4.3' "$CASK_PATH"
grep -q 'mlx-lm==0.31.2' "$CASK_PATH"
grep -q 'huggingface_hub==1.9.1' "$CASK_PATH"
if grep -q '"mlx",' "$CASK_PATH"; then
  echo "Runtime packages must be pinned in the generated cask" >&2
  exit 1
fi
grep -q 'whisper-large-v3-turbo' "$CASK_PATH"
grep -q 'Qwen3-4B-4bit' "$CASK_PATH"
if grep -q 'Qwen3-1.7B-4bit' "$CASK_PATH"; then
  echo "Qwen3 1.7B should not be bundled by default" >&2
  exit 1
fi
grep -q 'Digest::SHA256' "$CASK_PATH"
grep -q 'failed sha256 verification' "$CASK_PATH"
grep -q 'LIVENOTES_SUPPORT_ROOT' "$CASK_PATH"
grep -q 'LIVENOTES_CURL_BIN' "$CASK_PATH"
grep -q 'Installing LiveNotes local MLX runtime packages' "$CASK_PATH"
grep -q 'Downloading #{relative_path}' "$CASK_PATH"
grep -q 'Installed #{relative_path}' "$CASK_PATH"
grep -q 'LiveNotes local MLX runtime is ready' "$CASK_PATH"
grep -q 'app "LiveNotes.app"' "$CASK_PATH"
grep -q 'uninstall quit:' "$CASK_PATH"
grep -q 'delete: \[' "$CASK_PATH"
grep -q '~/Library/Application Support/LiveNotes/LiveNotesArtifacts' "$CASK_PATH"
grep -q '~/Library/Application Support/LiveNotes/Runtime' "$CASK_PATH"
grep -q 'trash:  "~/Library/Preferences/app.livenotes.mac.plist"' "$CASK_PATH"
grep -q 'zap trash:' "$CASK_PATH"
grep -q '~/Library/Application Support/LiveNotes' "$CASK_PATH"
python3 - "$CASK_PATH" <<'PYTHON'
import re
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"uninstall\b(?P<body>.*?)\n\n  zap\b", content, re.S)
if not match:
    raise SystemExit("Generated cask is missing an uninstall stanza")
body = match.group("body")
preserved_paths = [
    "~/Library/Application Support/LiveNotes/sessions.json",
    "~/Library/Application Support/LiveNotes/Audio",
    "~/Library/Application Support/LiveNotes/Exports",
]
for path in preserved_paths:
    if path in body:
        raise SystemExit(f"Regular uninstall must preserve user content: {path}")
PYTHON
grep -q 'LIVENOTES_REQUIRE_SIGNED_APP' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'LIVENOTES_NOTARIZE_APP' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'Developer ID Application' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'xcrun notarytool submit' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'xcrun stapler validate' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'spctl --assess' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'Select Xcode with Swift 6' "$WORKFLOW_PATH"
grep -q 'xcode-version: latest-stable' "$WORKFLOW_PATH"
grep -q 'Select Xcode with Swift 6' "$CI_WORKFLOW_PATH"
grep -q 'xcode-version: latest-stable' "$CI_WORKFLOW_PATH"
grep -q 'timeout-minutes: 8' "$CI_WORKFLOW_PATH"
grep -q 'LIVENOTES_RECORDING_PIPELINE_LIVE: "0"' "$CI_WORKFLOW_PATH"
grep -q './scripts/run-core-tests.sh' "$CI_WORKFLOW_PATH"
grep -q 'brew install ffmpeg' "$CI_WORKFLOW_PATH"
grep -q 'LIVENOTES_UI_MIN_VIDEO_SECONDS: "0"' "$CI_WORKFLOW_PATH"
grep -q 'swift test --disable-sandbox --disable-xctest list' "$ROOT_DIR/scripts/run-core-tests.sh"
grep -q 'swift test --disable-sandbox --disable-xctest --skip-build --filter' "$ROOT_DIR/scripts/run-core-tests.sh"
grep -q 'actions/setup-python@v6' "$WORKFLOW_PATH"
grep -q 'python-version: "3.12"' "$WORKFLOW_PATH"
grep -q 'scripts/release-requirements.txt' "$WORKFLOW_PATH"
grep -q 'python3.12 -m pip install -r scripts/release-requirements.txt' "$WORKFLOW_PATH"
grep -q 'LIVENOTES_PYTHON: python3.12' "$WORKFLOW_PATH"
grep -q 'timeout-minutes: 8' "$WORKFLOW_PATH"
grep -q 'LIVENOTES_RECORDING_PIPELINE_LIVE: "0"' "$WORKFLOW_PATH"
grep -q './scripts/run-core-tests.sh' "$WORKFLOW_PATH"
grep -q 'brew install ffmpeg' "$WORKFLOW_PATH"
grep -q 'LIVENOTES_UI_MIN_VIDEO_SECONDS: "0"' "$WORKFLOW_PATH"
if grep -q 'scripts/benchmark-requirements.txt' "$WORKFLOW_PATH"; then
  echo "Release workflow must not install benchmark-only dependencies" >&2
  exit 1
fi
grep -q './scripts/check-release-readiness.sh' "$WORKFLOW_PATH"
if grep -q 'Run quality benchmark' "$WORKFLOW_PATH"; then
  echo "Release workflow must use the saved model selection and not rerun selection benchmarks" >&2
  exit 1
fi
grep -q 'require_value HOMEBREW_TAP_TOKEN' "$WORKFLOW_PATH"
grep -q 'sign_and_notarize=0' "$WORKFLOW_PATH"
grep -q 'sign_and_notarize=1' "$WORKFLOW_PATH"
grep -q 'Apple notarization secrets must be all set or all omitted' "$WORKFLOW_PATH"
grep -q 'Homebrew preview build' "$WORKFLOW_PATH"
grep -q 'DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64' "$WORKFLOW_PATH"
grep -q 'APPLE_APP_SPECIFIC_PASSWORD' "$WORKFLOW_PATH"
grep -q "publish=\\\"1\\\"" "$WORKFLOW_PATH"
grep -q 'if-no-files-found: ignore' "$WORKFLOW_PATH"
grep -q -- '--notes-file' "$WORKFLOW_PATH"
grep -q 'gh release edit "$release_tag"' "$WORKFLOW_PATH"
if grep -Eq -- '--notes[[:space:]].*`brew install' "$WORKFLOW_PATH"; then
  echo "Release notes must not execute brew install command substitution" >&2
  exit 1
fi
grep -q 'tag="$GITHUB_REF_NAME"' "$WORKFLOW_PATH"
if grep -q 'echo "tag=v$version"' "$WORKFLOW_PATH"; then
  echo "Tagged releases must keep the triggering tag in release URLs" >&2
  exit 1
fi
python3 - "$WORKFLOW_PATH" <<'PYTHON'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text(encoding="utf-8")
checks = {
    "resolve": content.find("- name: Resolve version"),
    "credentials": content.find("- name: Resolve publish mode"),
    "tests": content.find("- name: Run core tests"),
}
if any(index == -1 for index in checks.values()):
    raise SystemExit("Release workflow is missing a required release step")
if not checks["resolve"] < checks["credentials"] < checks["tests"]:
    raise SystemExit("Release publish credentials must be validated before tests")
PYTHON
if [[ -f "$ROOT_DIR/.github/workflows/release-desktop.yml" ]]; then
  echo "Offline DMG workflow must not be a release path" >&2
  exit 1
fi
grep -q 'import importlib.util' "$APP_MODEL_PATH"
grep -q 'importlib.util.find_spec' "$APP_MODEL_PATH"
if grep -q 'import mlx; import mlx_whisper; import mlx_lm' "$APP_MODEL_PATH"; then
  echo "Production runtime readiness must not cold-import MLX packages on app launch" >&2
  exit 1
fi

FAKE_PREFIX="$WORK_ROOT/homebrew"
FAKE_SUPPORT="$WORK_ROOT/support"
FAKE_CURL="$WORK_ROOT/curl.sh"
POSTFLIGHT_CASK="$WORK_ROOT/livenotes-postflight.rb"
POSTFLIGHT_SMOKE="$WORK_ROOT/postflight-smoke.rb"
FIXTURE_SHA="e80b71cd14d3cbd65f4173abcbfcf01a545dbca32a72d575108b553a648cc96f"
mkdir -p "$FAKE_PREFIX/bin"

cat > "$FAKE_PREFIX/bin/python3.12" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

if [[ "$1" == "-m" && "$2" == "venv" ]]; then
  runtime_root="$3"
  mkdir -p "$runtime_root/bin"
  cat > "$runtime_root/bin/python3" <<'PYTHON'
#!/usr/bin/env bash

set -euo pipefail

if [[ "$1" == "-m" && "$2" == "pip" && "$3" == "install" ]]; then
  printf '%s\n' "$@" > "$(dirname "$0")/../pip-install-args.txt"
  exit 0
fi

echo "Unsupported runtime python command: $*" >&2
exit 64
PYTHON
  chmod +x "$runtime_root/bin/python3"
  exit 0
fi

echo "Unsupported python command: $*" >&2
exit 64
SCRIPT
chmod +x "$FAKE_PREFIX/bin/python3.12"

cat > "$FAKE_CURL" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

output_path=""
while (( $# > 0 )); do
  case "$1" in
    --output)
      output_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$output_path" ]]; then
  echo "Missing curl output path" >&2
  exit 64
fi
printf 'fixture\n' > "$output_path"
SCRIPT
chmod +x "$FAKE_CURL"

ruby - "$CASK_PATH" "$POSTFLIGHT_CASK" "$FIXTURE_SHA" <<'RUBY'
source_path, output_path, fixture_sha = ARGV
content = File.read(source_path)
replacement = <<~TEXT
    artifacts = [
      ["https://example.invalid/model.bin", "models/fixture.bin", 8, "#{fixture_sha}"],
    ]

    artifacts.each
TEXT
content.sub!(/    artifacts = \[.*?\n    artifacts\.each do \|remote_url, relative_path, expected_size, expected_sha\|/m, replacement.chomp + " do |remote_url, relative_path, expected_size, expected_sha|")
File.write(output_path, content)
RUBY

cat > "$POSTFLIGHT_SMOKE" <<'RUBY'
def cask(_name)
  yield
end

def version(*); end
def sha256(*); end
def url(*); end
def name(*); end
def desc(*); end
def homepage(*); end
def depends_on(*); end
def app(*); end
def uninstall(*); end
def zap(*); end

def postflight(&block)
  block.call
end

def system_command(command, args:)
  raise "Command failed: #{command} #{args.join(' ')}" unless system(command, *args)
end

load ARGV.fetch(0)
RUBY

HOMEBREW_PREFIX="$FAKE_PREFIX" \
LIVENOTES_SUPPORT_ROOT="$FAKE_SUPPORT" \
LIVENOTES_CURL_BIN="$FAKE_CURL" \
  ruby "$POSTFLIGHT_SMOKE" "$POSTFLIGHT_CASK" > "$WORK_ROOT/postflight.log"

grep -q 'Installing LiveNotes local MLX runtime packages' "$WORK_ROOT/postflight.log"
grep -q 'Downloading models/fixture.bin (0.0 MB)' "$WORK_ROOT/postflight.log"
grep -q 'Installed models/fixture.bin' "$WORK_ROOT/postflight.log"
grep -q 'LiveNotes local MLX runtime is ready' "$WORK_ROOT/postflight.log"

if [[ ! -f "$FAKE_SUPPORT/Runtime/pip-install-args.txt" ]]; then
  echo "Expected postflight to install the local Python runtime packages" >&2
  exit 1
fi
if [[ "$(cat "$FAKE_SUPPORT/LiveNotesArtifacts/models/fixture.bin")" != "fixture" ]]; then
  echo "Expected postflight to download and verify model artifacts" >&2
  exit 1
fi

printf '%s\n' "$CASK_PATH"
