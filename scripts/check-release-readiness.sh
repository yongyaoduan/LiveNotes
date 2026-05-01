#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_FILE="$ROOT_DIR/LiveNotesCore/Sources/LiveNotesCore/RecordingPipeline.swift"
APP_MODEL_FILE="$ROOT_DIR/LiveNotesApp/AppModel.swift"
PROJECT_FILE="$ROOT_DIR/LiveNotes.xcodeproj/project.pbxproj"
ENTITLEMENTS_FILE="$ROOT_DIR/LiveNotesApp/LiveNotes.entitlements"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release-homebrew.yml"
WORK_ROOT="$(mktemp -d /tmp/livenotes-release-readiness.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT
APP_ZIP_PATH="${1:-${LIVENOTES_APP_ZIP_PATH:-}}"
APP_ZIP_SHA256="${2:-${LIVENOTES_APP_ZIP_SHA256:-}}"
UI_EVIDENCE_DIR="${LIVENOTES_UI_EVIDENCE_DIR:-$ROOT_DIR/dist/ui-evidence}"
RELEASE_VERSION="${LIVENOTES_RELEASE_VERSION:-0.1.0}"

require_file() {
  local path="$1"
  local message="$2"
  if [[ ! -f "$path" ]]; then
    echo "Release blocked: $message" >&2
    exit 1
  fi
}

require_grep() {
  local pattern="$1"
  local path="$2"
  local message="$3"
  if ! grep -q "$pattern" "$path"; then
    echo "Release blocked: $message" >&2
    exit 1
  fi
}

reject_grep() {
  local pattern="$1"
  local path="$2"
  local message="$3"
  if grep -Eq "$pattern" "$path"; then
    echo "Release blocked: $message" >&2
    exit 1
  fi
}

validate_ui_video() {
  local path="$1"
  local label="$2"
  local duration

  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "Release blocked: ffprobe is required to validate UI evidence video files." >&2
    exit 1
  fi

  if ! duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$path" 2>/dev/null)"; then
    echo "Release blocked: UI evidence $label is not a readable video file." >&2
    exit 1
  fi

  awk -v duration="$duration" -v label="$label" 'BEGIN {
    if (duration + 0 <= 0) {
      printf "Release blocked: UI evidence %s has no video duration.\n", label > "/dev/stderr"
      exit 1
    }
  }'
}

validate_ui_evidence() {
  local summary_path="$UI_EVIDENCE_DIR/summary.json"
  local log_path="$UI_EVIDENCE_DIR/xcodebuild.log"

  require_file "$summary_path" "UI evidence summary is missing."
  require_file "$log_path" "UI evidence test log is missing."

  mapfile -t ui_video_paths < <(ruby -rjson - "$summary_path" "$ROOT_DIR" <<'RUBY'
summary_path, root_dir = ARGV
summary = JSON.parse(File.read(summary_path))
abort "Release blocked: UI evidence must include screenshots." unless summary.fetch("screenshots", 0).to_i > 0
["video", "screenshotTimelineVideo"].each do |key|
  value = summary[key].to_s
  abort "Release blocked: UI evidence is missing #{key}." if value.empty?
  path = File.absolute_path(value, root_dir)
  abort "Release blocked: UI evidence file does not exist: #{value}" unless File.file?(path)
  abort "Release blocked: UI evidence file is empty: #{value}" unless File.size(path).positive?
  puts "#{key}\t#{path}"
end
RUBY
  )

  for entry in "${ui_video_paths[@]}"; do
    validate_ui_video "${entry#*$'\t'}" "${entry%%$'\t'*}"
  done

  if ! grep -Eq 'TEST SUCCEEDED|with 0 failures' "$log_path"; then
    echo "Release blocked: UI evidence tests did not pass." >&2
    exit 1
  fi
  if ! grep -Eq 'Executed [0-9]+ tests?, with 0 failures' "$log_path"; then
    echo "Release blocked: UI evidence log is missing the xcodebuild test summary." >&2
    exit 1
  fi
  for required_test in \
    testFinalSaveWaitsForGeneratedTranslations \
    testFinalSaveContinuesWhenTranslationIsUnavailable \
    testFinalSaveContinuesWhenTranslationDoesNotReturn \
    testEmptyFinalInferenceDoesNotSaveLivePreviewTranscript \
    testFailedFinalInferenceDoesNotSaveLivePreviewTranscript \
    testFinalFileTranscriptOverridesCommittedLiveTranscript \
    testFailedFinalInferenceSavesCommittedLiveTranscript \
    testSavedReviewExportsMarkdown
  do
    if ! grep -q "$required_test" "$log_path"; then
      echo "Release blocked: UI evidence log is missing $required_test." >&2
      exit 1
    fi
  done
}

validate_app_zip() {
  local zip_path="$1"
  local expected_sha="$2"
  local computed_sha
  local cask_path
  local entries_path="$WORK_ROOT/app-zip-entries.txt"

  require_file "$zip_path" "Homebrew app zip is missing."
  computed_sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
  if [[ -n "$expected_sha" && "$computed_sha" != "$expected_sha" ]]; then
    echo "Release blocked: Homebrew app zip sha256 does not match." >&2
    exit 1
  fi

  zipinfo -1 "$zip_path" > "$entries_path"
  require_grep '^LiveNotes\.app/Contents/MacOS/LiveNotes$' "$entries_path" "Homebrew app zip must contain LiveNotes.app."
  reject_grep '(^|/)\._|(^|/)\.DS_Store$' \
    "$entries_path" \
    "Homebrew app zip must not contain macOS metadata files."
  reject_grep '(^|/)Runtime/|LiveNotesArtifacts|livenotes_mlx_pipeline\.py|\.safetensors$|(^|/)models/|python|mlx' \
    "$entries_path" \
    "Homebrew app zip must not contain Python, MLX, model files, or legacy runtime artifacts."

  cask_path="$WORK_ROOT/livenotes-artifact.rb"
  "$ROOT_DIR/scripts/write-homebrew-cask.sh" \
    "$RELEASE_VERSION" \
    "${LIVENOTES_APP_ZIP_URL:-https://github.com/yongyaoduan/LiveNotes/releases/download/v$RELEASE_VERSION/LiveNotes-$RELEASE_VERSION.zip}" \
    "$computed_sha" \
    "$cask_path" >/dev/null
  ruby -c "$cask_path" >/dev/null
  require_grep 'app "LiveNotes.app"' "$cask_path" "Generated cask must install LiveNotes.app."
  require_grep 'depends_on macos: ">= :tahoe"' "$cask_path" "Homebrew cask must require macOS 26 or newer."
  require_grep 'Privacy & Security' "$cask_path" "Preview cask must explain unsigned launch recovery."
  reject_grep 'python@3\.12|Runtime/bin/python3|venv|pip install|mlx|postflight do|curl|LiveNotes local MLX runtime|topic notes' \
    "$cask_path" \
    "Homebrew cask must not install Python, MLX packages, model artifacts, or topic-note release copy."
}

require_file "$PIPELINE_FILE" "production recording pipeline is missing."
require_file "$APP_MODEL_FILE" "app model is missing."
require_file "$PROJECT_FILE" "Xcode project is missing."
require_file "$ENTITLEMENTS_FILE" "release entitlements file is missing."

if [[ -f "$ROOT_DIR/LiveNotesCore/Sources/LiveNotesCore/LocalModelBundle.swift" ]]; then
  echo "Release blocked: production sources must not include the retired model bundle verifier." >&2
  exit 1
fi

require_grep '^@preconcurrency import AVFoundation$' "$PIPELINE_FILE" "recording pipeline must use AVFoundation."
require_grep 'AVAudioEngine()' "$PIPELINE_FILE" "recording pipeline must use AVAudioEngine capture."
require_grep 'AVAudioApplication.shared.recordPermission' "$PIPELINE_FILE" "recording pipeline must use native AVAudioApplication microphone permission."
require_grep 'AVAudioApplication.requestRecordPermission' "$PIPELINE_FILE" "recording pipeline must request native AVAudioApplication microphone permission."
require_grep 'AVCaptureDevice.requestAccess(for: .audio)' "$PIPELINE_FILE" "recording pipeline must request undetermined microphone permission before audio input."
require_grep 'SpeechRecognitionPermissionAuthorizer' "$PIPELINE_FILE" "recording pipeline must gate speech recognition permission before startup."
require_grep 'SpeechAnalyzerTranscriptAssembler' "$PIPELINE_FILE" "recording pipeline must separate volatile previews from committed transcript segments."
require_grep 'func startRecording(to url: URL) async throws' "$PIPELINE_FILE" "microphone access must be non-blocking."
require_grep 'func start(' "$PIPELINE_FILE" "live transcription start API is missing."
require_grep ') async throws' "$PIPELINE_FILE" "speech authorization must be non-blocking."
require_grep 'microphonePermissionAuthorizer: \.preflightGranted' "$APP_MODEL_FILE" "production recording engine must not request microphone permission after preflight."
require_grep 'SpeechRecognitionPermissionAuthorizer.live.authorize()' "$APP_MODEL_FILE" "production preflight must include speech recognition permission before session creation."
require_grep 'MACOSX_DEPLOYMENT_TARGET = 26.4' "$PROJECT_FILE" "latest Apple Speech and Translation support requires macOS 26.4 or newer."
require_grep 'CODE_SIGN_ENTITLEMENTS = LiveNotesApp/LiveNotes.entitlements' "$PROJECT_FILE" "release app must include signing entitlements."
require_grep 'com.apple.security.device.audio-input' "$ENTITLEMENTS_FILE" "release entitlements must allow audio input under hardened runtime."
require_grep 'NativeSpeechLiveTranscriber' "$PIPELINE_FILE" "production live transcription must use Apple Speech."
require_grep 'NativeSpeechInferenceRunner' "$PIPELINE_FILE" "production final transcription must use Apple Speech."
require_grep 'SpeechAnalyzer' "$PIPELINE_FILE" "production transcription must use the latest Apple Speech analyzer."
require_grep 'SpeechTranscriber' "$PIPELINE_FILE" "production transcription must use the latest Apple Speech transcriber."
require_grep 'AssetInventory' "$PIPELINE_FILE" "production transcription must use Apple Speech asset management."
require_grep 'TranslationSession' "$APP_MODEL_FILE" "production translation must use Apple Translation."
require_grep 'TranslationSession' "$ROOT_DIR/LiveNotesApp/ContentView.swift" "production translation task bridge is missing."
require_grep 'preferredStrategy: \.lowLatency' "$ROOT_DIR/LiveNotesApp/ContentView.swift" "live translation must request low-latency Apple Translation."
require_grep 'LanguageAvailability(preferredStrategy: \.lowLatency)' "$APP_MODEL_FILE" "recording preflight must verify Apple Translation language availability."
require_grep 'TranslationSession.Request' "$APP_MODEL_FILE" "production translation must batch pending text with stable client identifiers."
require_grep 'translate(batch: requests)' "$APP_MODEL_FILE" "production translation must stream batch responses."
require_grep 'activeTranslationSession.*cancel()' "$APP_MODEL_FILE" "translation timeouts must cancel the active Apple Translation session."
require_grep 'markTranslationGenerationCancelled' "$APP_MODEL_FILE" "translation timeout must cancel the affected transcript generation."
require_grep 'isTranslationJobCancelled' "$APP_MODEL_FILE" "canceled in-flight translation jobs must not be requeued."
require_grep 'pendingFinalSaves' "$APP_MODEL_FILE" "final save must wait until generated translations are persisted."
require_grep 'savedTranscript' "$PIPELINE_FILE" "release report must cover saved transcripts."
require_grep 'AudioTapBufferSize.frameCount' "$PIPELINE_FILE" "audio capture must use a duration-derived tap buffer size."
require_grep 'AnalyzerInput(buffer: convertedBuffer)' "$PIPELINE_FILE" "SpeechAnalyzer live input must use inferred contiguous timing."
require_grep 'func finish() async -> \[TranscriptSentence\]' "$PIPELINE_FILE" "live transcription finish must drain committed results before saving."
require_grep 'analyzeSequence(from: audioFile)' "$PIPELINE_FILE" "final transcription must use SpeechAnalyzer file input."
require_grep 'finalizeAndFinishThroughEndOfInput()' "$PIPELINE_FILE" "SpeechAnalyzer finalization must drain through end of input."
require_grep 'let activeJobs = jobs.filter' "$APP_MODEL_FILE" "canceled translation failures must not requeue stale in-flight jobs."
reject_grep 'NativeTopicSummarizer|Current Topic|Topic Notes|topic notes|topic summaries' \
  "$ROOT_DIR/LiveNotesApp/ContentView.swift" \
  "v0.1 UI must stay focused on recording, transcription, translation, and saved transcripts."

reject_grep 'LocalMLXRecordingInferenceRunner|SwiftWhisperTranscriber|SwiftQwenRunner|LocalModelBundleVerifier|localModelReadiness' \
  "$APP_MODEL_FILE" \
  "production app must not gate Apple services on bundled MLX models."
reject_grep 'LocalMLXInferenceRunner|LocalMLXRecordingInferenceRunner|SwiftWhisperTranscriber|SwiftQwenRunner|RuntimeOutput|RuntimeTranscriptSentence' \
  "$PIPELINE_FILE" \
  "production pipeline must not require the retired Swift MLX release path."
reject_grep 'LocalModelBundle.swift' \
  "$PROJECT_FILE" \
  "Xcode project must not compile the retired model bundle verifier."
reject_grep 'translations\(from: requests\)' \
  "$APP_MODEL_FILE" \
  "production translation must not wait for all batch responses before updating the UI."
reject_grep 'bufferStartTime:' \
  "$PIPELINE_FILE" \
  "SpeechAnalyzer live input must not manually stamp contiguous microphone buffers."
reject_grep 'bufferSize: 4_096|bufferSize: 4096' \
  "$PIPELINE_FILE" \
  "audio tap buffer size must not be a fixed frame count."

reject_grep 'importlib|pythonCanImportMLXRuntime|Local MLX runtime|LIVENOTES_PYTHON|livenotes_mlx_pipeline.py' \
  "$APP_MODEL_FILE" \
  "production app model must not check Python or MLX runtime readiness."
reject_grep 'Test MLX pipeline helper|Test bundled artifact preparation script|Test model artifact verifier|Test quality benchmark harness' \
  "$CI_WORKFLOW" \
  "CI must not use legacy MLX release gates for the Homebrew app."
require_grep 'Check release readiness' "$RELEASE_WORKFLOW" "Homebrew release workflow must run the release readiness gate before publishing."
require_grep './scripts/check-release-readiness.sh' "$RELEASE_WORKFLOW" "Homebrew release workflow must run the release readiness gate before publishing."
reject_grep 'actions/setup-python|scripts/release-requirements.txt|LIVENOTES_PYTHON' \
  "$RELEASE_WORKFLOW" \
  "Homebrew release workflow must not install Python or run MLX release gates."

CASK_PATH="$WORK_ROOT/livenotes.rb"
"$ROOT_DIR/scripts/write-homebrew-cask.sh" \
  "0.1.0" \
  "https://github.com/yongyaoduan/LiveNotes/releases/download/v0.1.0/LiveNotes-0.1.0.zip" \
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  "$CASK_PATH" >/dev/null

ruby -c "$CASK_PATH" >/dev/null
require_grep 'depends_on macos: ">= :tahoe"' "$CASK_PATH" "Homebrew cask must require macOS 26 or newer."
require_grep 'Privacy & Security' "$CASK_PATH" "Preview cask must explain unsigned launch recovery."
reject_grep 'python@3\.12|Runtime/bin/python3|venv|pip install|mlx|postflight do|curl|LiveNotes local MLX runtime' \
  "$CASK_PATH" \
  "Homebrew cask must not install Python, MLX packages, or model artifacts."

if [[ -z "$APP_ZIP_PATH" ]]; then
  echo "Release blocked: Homebrew app zip path is required." >&2
  exit 64
fi
validate_app_zip "$APP_ZIP_PATH" "$APP_ZIP_SHA256"
validate_ui_evidence

printf 'Release readiness passed.\n'
