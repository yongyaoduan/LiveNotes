# Native speech CI

On September 14, 2026, the GitHub-hosted `macos-26` runner built the app and passed all 98 core tests, but produced no transcript in the real audio XCUITest. A separate capability probe on the same runner image confirmed that `SpeechTranscriber.isAvailable` is false:

- Original failure: https://github.com/yongyaoduan/LiveNotes/actions/runs/34811024988
- Capability probe: https://github.com/yongyaoduan/LiveNotes/actions/runs/34826349622

The same probe returns true on the development Mac. Apple defines this property as hardware and capability availability: https://developer.apple.com/documentation/speech/speechtranscriber/isavailable

`ci.yml` runs builds, core tests, ordinary UI evidence, and packaging on GitHub-hosted macOS. Pushes to `main` additionally call `native-speech.yml`, which requires a supported Mac with these runner labels:

```
self-hosted, macOS, ARM64, livenotes-native-speech
```

The Mac needs macOS 26+, Xcode with Swift 6, an active graphical login, and permission for XCTest to automate the app and grant the native Speech prompt. The native job generates an audio fixture and runs the production SpeechAnalyzer via XCUITest. It retains the xcresult, fixture checksum, and logs on failure. The capability probe fails if the speech runtime is unavailable; there is no synthetic inference fallback.

Pull requests do not run on this personal-machine runner. The release workflow waits for the native job to pass before publishing. A missing or offline runner leaves this check queued and blocks release; it does not count as passing. Runner registration is a separate infrastructure setup and must be completed before this check can execute.

Run the same check interactively on a supported Mac:

```bash
swiftc -parse-as-library scripts/check-native-speech.swift -o /tmp/livenotes-check-native-speech
/tmp/livenotes-check-native-speech
./scripts/run-loopback-e2e-test.sh
```

## Temporary runner validation and cleanup

On September 14, a user-authorized ephemeral runner on the development Mac executed the native job for commit `903fb4097dc0b94d65ddec9ea724936a5eb58ab4` in [CI run 34827192589](https://github.com/yongyaoduan/LiveNotes/actions/runs/34827192589). The production audio XCUITest passed with zero failures in 32.747 seconds, and the native evidence artifact was uploaded successfully.

The runner then exited and automatically removed its GitHub registration. Its installation, credentials, separate DerivedData directory, and temporary fixture/session files were removed. No background runner service was installed. The successful xcresult and logs were retained under `.cache/ci-validation-2026-09-14/native-e2e` as well as in the GitHub artifact. Rebuildable release/trace build directories and decoded video frames were cleaned; original validation videos and OCR/review logs were retained.

Future native CI and releases require another temporary runner session on a supported Mac. There is intentionally no permanently online runner after cleanup.

The full CI run completed successfully: core tests passed; the hosted UI suite ran 42 tests with zero failures and one native-only test skipped, and that same native test passed separately on the temporary Mac runner. All hosted packaging and release-readiness regression checks passed. The published v1.0.2 archive checksum still matches the local archive, and all six installed application files match the release archive byte-for-byte; no replacement release asset was needed for these CI-only changes.
