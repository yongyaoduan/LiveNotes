# LiveNotes

LiveNotes is a native macOS app for local live recording, transcription, English-to-Chinese translation, topic notes, and saved transcripts.

The product keeps the interface focused on four jobs:

- Transcribe the session while recording.
- Translate complete English sentences into Chinese.
- Split notes into topics as the session moves on.
- Save audio, transcript, translation, and topic summaries for review.

## Models

The release bundle is local-only. It uses:

- `mlx-community/whisper-medium-mlx` for transcription.
- `mlx-community/Qwen3-4B-4bit` for topic summaries.
- `mlx-community/Qwen3-1.7B-4bit` for English-to-Chinese translation.

Only English-to-Chinese translation is supported in this version.

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

## Release

Prepare local model artifacts:

```bash
./scripts/prepare-bundled-artifacts.sh .cache
```

Build a DMG:

```bash
LIVENOTES_BUNDLED_ARTIFACT_SOURCE_ROOT=.cache ./scripts/build-dmg.sh
```

The release workflow runs on tags matching `*.*.*` or `desktop-v*`. It runs Swift tests, builds the app, runs XCUITest, prepares bundled model artifacts, builds a DMG, uploads the artifact, and publishes a GitHub Release.
