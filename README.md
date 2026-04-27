# LiveNotes

LiveNotes is a native macOS app for local recording notes, English-to-Chinese translation, topic summaries, and saved transcripts.

Current release status: the native app shell, AVAudioEngine recording path, local MLX inference path, persistence layer, UI evidence coverage, model artifact locks, and live model checks are in place. A Homebrew preview release can be published after the release gate passes with real audio.

The product keeps the interface focused on four jobs:

- Transcribe the session while recording.
- Translate complete English sentences into Chinese.
- Split notes into topics as the session moves on.
- Save audio, transcript, translation, and topic summaries for review.

## Models

LiveNotes runs models locally. It uses:

- `mlx-community/whisper-large-v3-turbo` for transcription.
- `mlx-community/Qwen3-4B-4bit` for topic summaries.
- `mlx-community/Qwen3-4B-4bit` for English-to-Chinese translation.

Model artifacts are used in their locked MLX formats. Whisper Large v3 Turbo uses the official MLX `safetensors` weights with F16 tensors. Qwen3 4B uses the 4-bit MLX repository: quantized weight tensors must stay stored as `U32`, quantization scales and biases must stay `BF16`, and the official config must keep `torch_dtype=bfloat16`, `bits=4`, and `group_size=64`. Release checks fail if these precision settings drift.

Only English-to-Chinese translation is supported in this version.

## Install

The Homebrew install command is:

```bash
brew install yongyaoduan/livenotes/livenotes
```

The cask installs the app, creates the local MLX runtime in `~/Library/Application Support/LiveNotes/Runtime`, and downloads model artifacts to `~/Library/Application Support/LiveNotes/LiveNotesArtifacts`.

Preview builds are not signed with Developer ID or notarized by Apple. macOS may block first launch until the app is allowed from System Settings. The same Homebrew cask becomes the production release path after Apple Developer Program signing credentials are configured.

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

Test the DMG script with fixture artifacts:

```bash
./scripts/test-build-dmg.sh
```

Test Homebrew and model preparation scripts:

```bash
./scripts/test-homebrew-cask.sh
./scripts/test-prepare-bundled-artifacts.sh
./scripts/test-model-artifact-verifier.sh
```

Run the fixture quality gate:

```bash
./scripts/test-quality-benchmark.sh
```

Run the live release readiness gate before release. This checks real audio capture, the local Swift pipeline, the fixed MLX model artifacts, transcription, translation, and topic generation:

```bash
./scripts/check-release-readiness.sh
```

The model choice is fixed for the product: Whisper Large v3 Turbo for transcription and Qwen3 4B 4-bit for translation and topic summaries. Historical 100-sample comparison reports are kept under `dist/quality-benchmark/` only as engineering evidence.

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

The `Release Homebrew` workflow runs on tags matching `v*`, `desktop-v*`, or `*.*.*`, and it can also publish from GitHub Actions when a manual run provides a version. The workflow generates UI screenshot and video evidence, runs the release readiness gate, creates the GitHub release, and updates the Homebrew tap.

Homebrew preview publishing requires this GitHub secret:

- `HOMEBREW_TAP_TOKEN`

Signed and notarized publishing also requires these GitHub secrets:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

Do not publish a user-facing release until the production audio capture and local MLX inference pipeline passes the release quality gate and writes the pipeline readiness report.

Offline DMG packaging remains a local internal test path only. It is not a GitHub release workflow, and the user-facing distribution path is Homebrew.
