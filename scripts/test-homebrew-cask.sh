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
grep -q 'app "LiveNotes.app"' "$CASK_PATH"
grep -q 'depends_on arch: :arm64' "$CASK_PATH"
grep -q 'depends_on macos: ">= :tahoe"' "$CASK_PATH"
grep -q 'Privacy & Security' "$CASK_PATH"
grep -q 'Open Anyway' "$CASK_PATH"
grep -q 'uninstall quit:' "$CASK_PATH"
grep -q 'delete: \[' "$CASK_PATH"
grep -q '~/Library/Application Support/LiveNotes/LiveNotesArtifacts' "$CASK_PATH"
grep -q '~/Library/Application Support/LiveNotes/Runtime' "$CASK_PATH"
grep -q 'trash:  "~/Library/Preferences/app.livenotes.mac.plist"' "$CASK_PATH"
grep -q 'zap trash:' "$CASK_PATH"
grep -q '~/Library/Application Support/LiveNotes' "$CASK_PATH"

if grep -Eq 'python@3\.12|Runtime/bin/python3|venv|pip install|mlx|postflight do|curl|LiveNotes local MLX runtime|topic notes' "$CASK_PATH"; then
  echo "Generated cask must not install Python, MLX packages, model artifacts, or topic-note release copy" >&2
  exit 1
fi

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
grep -q 'LiveNotesApp/LiveNotes.entitlements' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q -- '--entitlements "$ENTITLEMENTS_PATH"' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'com.apple.security.device.audio-input' "$ROOT_DIR/LiveNotesApp/LiveNotes.entitlements"
grep -q 'COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent' "$ROOT_DIR/scripts/build-homebrew-app-zip.sh"
grep -q 'Select Xcode with Swift 6' "$WORKFLOW_PATH"
grep -q 'xcode-version: latest-stable' "$WORKFLOW_PATH"
grep -q 'Select Xcode with Swift 6' "$CI_WORKFLOW_PATH"
grep -q 'xcode-version: latest-stable' "$CI_WORKFLOW_PATH"
grep -q './scripts/test-build-settings.sh' "$WORKFLOW_PATH"
grep -q './scripts/test-build-settings.sh' "$CI_WORKFLOW_PATH"
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = app.livenotes.mac.debug' "$ROOT_DIR/scripts/test-build-settings.sh"
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = app.livenotes.mac$' "$ROOT_DIR/scripts/test-build-settings.sh"
grep -q 'timeout-minutes: 8' "$CI_WORKFLOW_PATH"
grep -q './scripts/run-core-tests.sh' "$CI_WORKFLOW_PATH"
grep -q 'brew install ffmpeg' "$CI_WORKFLOW_PATH"
grep -q 'LIVENOTES_UI_MIN_VIDEO_SECONDS: "0"' "$CI_WORKFLOW_PATH"
grep -q 'MACOSX_DEPLOYMENT_TARGET = 26.4' "$ROOT_DIR/LiveNotes.xcodeproj/project.pbxproj"
grep -q 'CODE_SIGN_ENTITLEMENTS = LiveNotesApp/LiveNotes.entitlements' "$ROOT_DIR/LiveNotes.xcodeproj/project.pbxproj"
grep -q 'swift test --disable-sandbox --disable-xctest list' "$ROOT_DIR/scripts/run-core-tests.sh"
grep -q 'swift test --disable-sandbox --disable-xctest --skip-build --filter' "$ROOT_DIR/scripts/run-core-tests.sh"
grep -q 'timeout-minutes: 8' "$WORKFLOW_PATH"
grep -q './scripts/run-core-tests.sh' "$WORKFLOW_PATH"
grep -q 'brew install ffmpeg' "$WORKFLOW_PATH"
grep -q 'LIVENOTES_UI_MIN_VIDEO_SECONDS: "0"' "$WORKFLOW_PATH"
grep -q 'require_value HOMEBREW_TAP_TOKEN' "$WORKFLOW_PATH"
grep -q 'sign_and_notarize=0' "$WORKFLOW_PATH"
grep -q 'sign_and_notarize=1' "$WORKFLOW_PATH"
grep -q 'Apple notarization secrets must be all set or all omitted' "$WORKFLOW_PATH"
grep -q 'Homebrew preview build' "$WORKFLOW_PATH"
grep -q 'Check release readiness' "$WORKFLOW_PATH"
grep -q './scripts/check-release-readiness.sh' "$WORKFLOW_PATH"
grep -q 'steps.app_zip.outputs.zip_path' "$WORKFLOW_PATH"
grep -q 'steps.app_zip.outputs.sha256' "$WORKFLOW_PATH"
grep -q 'Test release readiness guard' "$CI_WORKFLOW_PATH"
grep -q './scripts/test-release-readiness.sh' "$CI_WORKFLOW_PATH"
grep -q 'This release is signed with Developer ID and submitted for Apple notarization.' "$WORKFLOW_PATH"
grep -q 'DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64' "$WORKFLOW_PATH"
grep -q 'APPLE_APP_SPECIFIC_PASSWORD' "$WORKFLOW_PATH"
grep -q "publish=\"1\"" "$WORKFLOW_PATH"
grep -q 'if-no-files-found: ignore' "$WORKFLOW_PATH"
grep -q -- '--notes-file' "$WORKFLOW_PATH"
grep -q 'gh release edit "$release_tag"' "$WORKFLOW_PATH"
grep -q 'tag="$GITHUB_REF_NAME"' "$WORKFLOW_PATH"

if grep -Eq 'actions/setup-python|python3\.12|scripts/release-requirements.txt|LIVENOTES_PYTHON|Test MLX pipeline helper|Test bundled artifact preparation script|Test model artifact verifier' "$WORKFLOW_PATH"; then
  echo "Homebrew release workflow must not install Python or run MLX release gates" >&2
  exit 1
fi
if grep -Eq 'Test MLX pipeline helper|Test bundled artifact preparation script|Test model artifact verifier|Test quality benchmark harness' "$CI_WORKFLOW_PATH"; then
  echo "CI must not run legacy MLX release gates for the Homebrew app" >&2
  exit 1
fi
if grep -q 'Run quality benchmark' "$WORKFLOW_PATH"; then
  echo "Release workflow must use the saved model selection and not rerun selection benchmarks" >&2
  exit 1
fi
if grep -Eq -- '--notes[[:space:]].*`brew install' "$WORKFLOW_PATH"; then
  echo "Release notes must not execute brew install command substitution" >&2
  exit 1
fi
if grep -q 'echo "tag=v$version"' "$WORKFLOW_PATH"; then
  echo "Tagged releases must keep the triggering tag in release URLs" >&2
  exit 1
fi
if [[ -f "$ROOT_DIR/.github/workflows/release-desktop.yml" ]]; then
  echo "Offline DMG workflow must not be a release path" >&2
  exit 1
fi
if grep -Eq 'importlib|pythonCanImportMLXRuntime|Local MLX runtime|LIVENOTES_PYTHON|livenotes_mlx_pipeline.py' "$APP_MODEL_PATH"; then
  echo "Production app model must not check Python or MLX runtime readiness" >&2
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
    "readiness": content.find("- name: Check release readiness"),
    "build_zip": content.find("- name: Build Homebrew app zip"),
}
if any(index == -1 for index in checks.values()):
    raise SystemExit("Release workflow is missing a required release step")
if not checks["resolve"] < checks["credentials"] < checks["tests"]:
    raise SystemExit("Release publish credentials must be validated before tests")
if not checks["tests"] < checks["build_zip"] < checks["readiness"]:
    raise SystemExit("Release readiness must validate the built Homebrew app zip before publishing")
PYTHON

printf '%s\n' "$CASK_PATH"
