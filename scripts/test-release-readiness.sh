#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/livenotes-release-readiness-test.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

LOG_PATH="$WORK_ROOT/release-readiness.log"
if "$ROOT_DIR/scripts/check-release-readiness.sh" >"$LOG_PATH" 2>&1; then
  echo "Release readiness must require the Homebrew app zip." >&2
  exit 1
fi
grep -q 'Homebrew app zip path is required' "$LOG_PATH"

APP_ROOT="$WORK_ROOT/app-root"
ZIP_PATH="$WORK_ROOT/LiveNotes-0.1.0.zip"
mkdir -p "$APP_ROOT/LiveNotes.app/Contents/MacOS"
printf 'fixture app\n' > "$APP_ROOT/LiveNotes.app/Contents/MacOS/LiveNotes"
chmod +x "$APP_ROOT/LiveNotes.app/Contents/MacOS/LiveNotes"
(
  cd "$APP_ROOT"
  zip -qry "$ZIP_PATH" LiveNotes.app
)
ZIP_SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to test release-readiness video validation" >&2
  exit 1
fi

BAD_EVIDENCE_DIR="$WORK_ROOT/bad-ui-evidence"
mkdir -p "$BAD_EVIDENCE_DIR"
printf 'video\n' > "$BAD_EVIDENCE_DIR/LiveNotesUITests.mov"
printf 'timeline\n' > "$BAD_EVIDENCE_DIR/LiveNotesUITests-screenshot-timeline.mov"
cat > "$BAD_EVIDENCE_DIR/summary.json" <<JSON
{
  "screenshots": 2,
  "video": "$BAD_EVIDENCE_DIR/LiveNotesUITests.mov",
  "screenshotTimelineVideo": "$BAD_EVIDENCE_DIR/LiveNotesUITests-screenshot-timeline.mov"
}
JSON
cat > "$BAD_EVIDENCE_DIR/xcodebuild.log" <<'LOG'
Test Suite 'All tests' passed.
	 Executed 27 tests, with 0 failures (0 unexpected) in 216.750 seconds
** TEST SUCCEEDED **
LOG
BAD_ARTIFACT_LOG_PATH="$WORK_ROOT/release-readiness-bad-video.log"
if LIVENOTES_UI_EVIDENCE_DIR="$BAD_EVIDENCE_DIR" \
  LIVENOTES_RELEASE_VERSION="0.1.0" \
  "$ROOT_DIR/scripts/check-release-readiness.sh" "$ZIP_PATH" "$ZIP_SHA" >"$BAD_ARTIFACT_LOG_PATH" 2>&1; then
  echo "Release readiness must reject unreadable UI evidence videos." >&2
  exit 1
fi
grep -q 'not a readable video file' "$BAD_ARTIFACT_LOG_PATH"

EVIDENCE_DIR="$WORK_ROOT/ui-evidence"
mkdir -p "$EVIDENCE_DIR"
ffmpeg -y -f lavfi -i color=c=white:s=320x240:d=1 -pix_fmt yuv420p \
  "$EVIDENCE_DIR/LiveNotesUITests.mov" >/dev/null 2>&1
ffmpeg -y -f lavfi -i color=c=white:s=320x240:d=1 -pix_fmt yuv420p \
  "$EVIDENCE_DIR/LiveNotesUITests-screenshot-timeline.mov" >/dev/null 2>&1
cat > "$EVIDENCE_DIR/summary.json" <<JSON
{
  "screenshots": 2,
  "video": "$EVIDENCE_DIR/LiveNotesUITests.mov",
  "screenshotTimelineVideo": "$EVIDENCE_DIR/LiveNotesUITests-screenshot-timeline.mov"
}
JSON
cat > "$EVIDENCE_DIR/xcodebuild.log" <<'LOG'
Test Suite 'All tests' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalSaveWaitsForGeneratedTranslations]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalSaveContinuesWhenTranslationIsUnavailable]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalSaveContinuesWhenTranslationDoesNotReturn]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testEmptyFinalInferenceDoesNotSaveLivePreviewTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFailedFinalInferenceDoesNotSaveLivePreviewTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalFileTranscriptOverridesCommittedLiveTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFailedFinalInferenceSavesCommittedLiveTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testProductionLoopbackRecordsTranscribesSavesAndExports]' skipped.
Test Case '-[LiveNotesUITests.LiveNotesUITests testSavedReviewExportsMarkdown]' passed.
	 Executed 27 tests, with 0 failures (0 unexpected) in 216.750 seconds
** TEST SUCCEEDED **
LOG
SKIPPED_ARTIFACT_LOG_PATH="$WORK_ROOT/release-readiness-skipped-e2e.log"
if LIVENOTES_UI_EVIDENCE_DIR="$EVIDENCE_DIR" \
  LIVENOTES_RELEASE_VERSION="0.1.0" \
  "$ROOT_DIR/scripts/check-release-readiness.sh" "$ZIP_PATH" "$ZIP_SHA" >"$SKIPPED_ARTIFACT_LOG_PATH" 2>&1; then
  echo "Release readiness must reject skipped production audio end-to-end UI tests." >&2
  exit 1
fi
grep -q 'production audio end-to-end UI test was skipped' "$SKIPPED_ARTIFACT_LOG_PATH"

cat > "$EVIDENCE_DIR/xcodebuild.log" <<'LOG'
Test Suite 'All tests' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalSaveWaitsForGeneratedTranslations]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalSaveContinuesWhenTranslationIsUnavailable]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalSaveContinuesWhenTranslationDoesNotReturn]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testEmptyFinalInferenceDoesNotSaveLivePreviewTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFailedFinalInferenceDoesNotSaveLivePreviewTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFinalFileTranscriptOverridesCommittedLiveTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testFailedFinalInferenceSavesCommittedLiveTranscript]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testProductionLoopbackRecordsTranscribesSavesAndExports]' passed.
Test Case '-[LiveNotesUITests.LiveNotesUITests testSavedReviewExportsMarkdown]' passed.
	 Executed 33 tests, with 0 failures (0 unexpected) in 216.750 seconds
** TEST SUCCEEDED **
LOG

ARTIFACT_LOG_PATH="$WORK_ROOT/release-readiness-artifact.log"
LIVENOTES_UI_EVIDENCE_DIR="$EVIDENCE_DIR" \
LIVENOTES_RELEASE_VERSION="0.1.0" \
  "$ROOT_DIR/scripts/check-release-readiness.sh" "$ZIP_PATH" "$ZIP_SHA" >"$ARTIFACT_LOG_PATH" 2>&1
grep -q 'Release readiness passed.' "$ARTIFACT_LOG_PATH"

if grep -Eq 'LIVENOTES_MLX_HELPER|prepare-bundled-artifacts|verify-model-artifacts|mlx_whisper|mlx_lm|local_mlx_inference' \
  "$ROOT_DIR/scripts/check-release-readiness.sh"; then
  echo "Release readiness guard must not use legacy Python MLX gates" >&2
  exit 1
fi

if grep -Eq "require_grep 'LocalMLXRecordingInferenceRunner|require_grep 'SwiftWhisperTranscriber|require_grep 'SwiftQwenRunner|require_grep 'LocalModelBundleVerifier" \
  "$ROOT_DIR/scripts/check-release-readiness.sh"; then
  echo "Release readiness guard must not require the retired Swift MLX release path" >&2
  exit 1
fi

if ! grep -Eq "require_grep 'NativeSpeechLiveTranscriber|require_grep 'NativeSpeechInferenceRunner|require_grep 'SpeechAnalyzer|require_grep 'SpeechTranscriber|require_grep 'TranslationSession" \
  "$ROOT_DIR/scripts/check-release-readiness.sh"; then
  echo "Release readiness guard must verify Apple Speech and Apple Translation gates" >&2
  exit 1
fi

grep -q 'validate_app_zip' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'validate_ui_evidence' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testFinalSaveWaitsForGeneratedTranslations' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testFinalSaveContinuesWhenTranslationIsUnavailable' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testFinalSaveContinuesWhenTranslationDoesNotReturn' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testEmptyFinalInferenceDoesNotSaveLivePreviewTranscript' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testFailedFinalInferenceDoesNotSaveLivePreviewTranscript' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testFinalFileTranscriptOverridesCommittedLiveTranscript' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testFailedFinalInferenceSavesCommittedLiveTranscript' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testSavedReviewExportsMarkdown' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'testProductionLoopbackRecordsTranscribesSavesAndExports' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'production audio end-to-end UI test was skipped' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'zipinfo -1' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q '\\._' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'savedTranscript' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'MACOSX_DEPLOYMENT_TARGET = 26.0' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -Fq 'if #available(macOS 26[.]4, [*])' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'LanguageAvailability(preferredStrategy: \\.lowLatency)' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'translate(batch: requests)' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'activeTranslationSession.*cancel()' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'markTranslationGenerationCancelled' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'isTranslationJobCancelled' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'AudioTapBufferSize.frameCount' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'AnalyzerInput(buffer: convertedBuffer)' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -Fq 'func finish() async -> \[TranscriptSentence\]' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'analyzeSequence(from: audioFile)' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'finalizeAndFinishThroughEndOfInput()' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'let activeJobs = jobs.filter' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'bufferStartTime:' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'bufferSize: 4_096|bufferSize: 4096' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -q 'Homebrew app zip path is required' "$ROOT_DIR/scripts/check-release-readiness.sh"
grep -Eq 'Executed \[0-9\]\+ tests\?, with 0 failures' "$ROOT_DIR/scripts/check-release-readiness.sh"

if grep -Eq 'NativeTopicSummarizer|Topic Notes|topic notes|topic summaries' "$ROOT_DIR/LiveNotesApp/ContentView.swift"; then
  echo "LiveNotes v0.1 UI must not expose topic summary features" >&2
  exit 1
fi

if grep -Eq 'depends_on macos: ">= :(sonoma|sequoia)"' "$ROOT_DIR/scripts/write-homebrew-cask.sh"; then
  echo "Homebrew cask must not advertise macOS 14 or macOS 15 support" >&2
  exit 1
fi

printf '%s\n' "$LOG_PATH"
