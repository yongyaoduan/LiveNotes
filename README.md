# LiveNotes

LiveNotes is a native macOS app for local live recording, transcription, English-to-Chinese translation, topic notes, and saved transcripts.

The product keeps the interface focused on four jobs:

- Transcribe the session while recording.
- Translate complete English sentences into Chinese.
- Split notes into topics as the session moves on.
- Save audio, transcript, translation, and topic summaries for review.

## Models

LiveNotes runs models locally. It uses:

- `mlx-community/whisper-medium-mlx` for transcription.
- `mlx-community/Qwen3-4B-4bit` for topic summaries.
- `mlx-community/Qwen3-1.7B-4bit` for English-to-Chinese translation.

Only English-to-Chinese translation is supported in this version.

## Install

Install with Homebrew:

```bash
brew tap yongyaoduan/livenotes
brew install --cask livenotes
```

You can also use the fully qualified cask name:

```bash
brew install yongyaoduan/livenotes/livenotes
```

The cask installs the app and downloads model artifacts to `~/Library/Application Support/LiveNotes/LiveNotesArtifacts`. After installation, the app runs recording, transcription, translation, and topic notes locally on this Mac.

## Development

Run core tests:

```bash
cd LiveNotesCore
swift test
```

Build the macOS app:

```bash
xcodebuild build -project LiveNotes.xcodeproj -scheme LiveNotes -destination 'platform=macOS'
```

Run UI tests:

```bash
./scripts/run-ui-tests.sh
```

Test the DMG script with fixture artifacts:

```bash
./scripts/test-build-dmg.sh
```

Test Homebrew and model preparation scripts:

```bash
./scripts/test-homebrew-cask.sh
./scripts/test-prepare-bundled-artifacts.sh
```

## Release

Build the app zip used by the Homebrew cask:

```bash
./scripts/build-homebrew-app-zip.sh
```

Generate a cask file:

```bash
./scripts/write-homebrew-cask.sh 0.1.0 <zip-url> <sha256>
```

The `Release Homebrew` workflow runs on tags matching `v*`, `desktop-v*`, or `*.*.*`, and it can also be run manually from GitHub Actions. It runs Swift tests, builds the app, runs XCUITest, verifies the Homebrew cask generator, uploads `LiveNotes.app.zip` to this repository's GitHub Release, and updates the tap cask.

`Build Offline DMG` remains available as a manual workflow for internal testing of a fully bundled offline DMG, but the user-facing distribution path is Homebrew.
