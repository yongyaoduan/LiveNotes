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

Test release asset splitting and model preparation:

```bash
./scripts/test-package-release-assets.sh
./scripts/test-prepare-bundled-artifacts.sh
```

## Release

Prepare local model artifacts:

```bash
./scripts/prepare-bundled-artifacts.sh .cache
```

Build a DMG with bundled models:

```bash
LIVENOTES_BUNDLED_ARTIFACT_SOURCE_ROOT=.cache ./scripts/build-dmg.sh
```

The release workflow runs on tags matching `*.*.*` or `desktop-v*`, and it can also be run manually from GitHub Actions. It runs Swift tests, builds the app, runs XCUITest, verifies the packaging scripts, prepares bundled model artifacts, builds a DMG, packages release assets, and uploads the result.

GitHub Release assets must stay below the per-file size limit, so the workflow can publish the offline DMG as split `.part-*` files with a restore script and SHA-256 checksum. The restored DMG still contains the bundled models.
