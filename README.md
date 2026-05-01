# LiveNotes

LiveNotes is a native macOS app for local recording, English-to-Chinese translation, and saved transcripts.

Current release status: the app uses Apple-native recording, speech recognition, and translation services. Homebrew publishing remains gated by automated tests, UI evidence, and release-readiness checks.

The product keeps the interface focused on four jobs:

- Transcribe the session while recording.
- Translate complete English sentences into Chinese.
- Save audio, transcript, and translation for review.
- Export saved transcripts when needed.

## Runtime

The production runtime is fixed:

- `AVAudioEngine` records microphone audio into the local library.
- Apple Speech `SpeechAnalyzer` and `SpeechTranscriber` provide English transcription.
- Apple Translation provides low-latency English-to-Chinese translation on macOS 26.4 or newer when available.
- LiveNotes shows volatile transcript text while recording and commits only finalized transcript segments.

Only English-to-Chinese translation is supported in this version.

## Install

The Homebrew install command is:

```bash
brew install yongyaoduan/livenotes/livenotes
```

The cask installs only `LiveNotes.app`. It does not install Python, create a virtual environment, or download model artifacts.

LiveNotes requires macOS 26 or newer. Low-latency English-to-Chinese translation requires macOS 26.4 or newer and installed translation assets.

Preview builds are published through the same Homebrew cask path. Signed and notarized releases are enabled after Apple Developer Program credentials are configured.

Preview builds are not Developer ID signed or notarized. If macOS blocks launch, open System Settings > Privacy & Security and choose Open Anyway.

Regular uninstall removes the app, preferences, and any legacy runtime artifacts while preserving saved recordings, transcripts, and exports:

```bash
brew uninstall --cask yongyaoduan/livenotes/livenotes
```

Full removal deletes all LiveNotes local data:

```bash
brew uninstall --zap --cask yongyaoduan/livenotes/livenotes
```

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

Run UI tests with screenshot and video evidence:

```bash
./scripts/record-ui-tests.sh
```

Test the internal DMG script:

```bash
./scripts/test-build-dmg.sh
```

Test Homebrew packaging:

```bash
./scripts/test-homebrew-cask.sh
```

## Release

Build the app zip used by the Homebrew cask:

```bash
./scripts/build-homebrew-app-zip.sh
```

Build a user-facing signed and notarized app zip:

```bash
LIVENOTES_REQUIRE_SIGNED_APP=1 LIVENOTES_NOTARIZE_APP=1 ./scripts/build-homebrew-app-zip.sh
```

Generate a cask file:

```bash
./scripts/write-homebrew-cask.sh 0.1.0 <zip-url> <sha256>
```

The `Release Homebrew` workflow runs on tags matching `v*`, `desktop-v*`, or `*.*.*`, and it can also publish from GitHub Actions when a manual run provides a version. The workflow generates UI screenshot and video evidence, runs the release readiness gate, creates the GitHub release, and updates the Homebrew tap only after the gate passes.

Homebrew preview publishing requires this GitHub secret:

- `HOMEBREW_TAP_TOKEN`

Signed and notarized publishing also requires these GitHub secrets:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

Do not publish a user-facing release until production audio capture, live transcription, translation, final save, and Homebrew install are verified on a local Mac.

Offline DMG packaging remains a local internal test path only. It is not a GitHub release workflow, and the user-facing distribution path is Homebrew.
