# Live Pipeline Technical Decision

Last reviewed: 2026-05-01

## Scope

LiveNotes records local microphone audio, shows live English transcription, translates finalized English text to Chinese, saves the transcript locally, and exports Markdown.

The current release should use Apple-native Speech and Translation APIs on the latest macOS SDK. It should not ship manual model packaging, Python runtimes, fixed-duration transcription slicing, or custom timestamp synthesis.

## Reference Set

Primary references:

- Apple WWDC25, "Bring advanced speech-to-text to your app with SpeechAnalyzer": https://developer.apple.com/videos/play/wwdc2025/277/
- Apple sample, "Bringing advanced speech-to-text capabilities to your app": https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app
- Apple Speech framework documentation, `SpeechAnalyzer`: https://developer.apple.com/documentation/speech/speechanalyzer
- Apple Translation documentation, "Translating text within your app": https://developer.apple.com/documentation/translation/translating-text-within-your-app
- Apple Translation documentation, `LanguageAvailability(preferredStrategy:)`: https://developer.apple.com/documentation/translation/languageavailability/init(preferredstrategy:)
- Installed macOS 26.4 SDK interfaces:
  - `SpeechAnalyzer.analyzeSequence(from: AVAudioFile)`
  - `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()`
  - `AnalyzerInput(buffer:)`
  - `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)`
  - `TranslationSession.translate(batch:)`
  - `TranslationSession.cancel()`

Realtime transcription references:

- Deepgram endpointing and interim results: https://developers.deepgram.com/docs/understand-endpointing-interim-results
- AssemblyAI Universal-3 Pro turn detection and partials: https://www.assemblyai.com/docs/streaming/universal-3-pro/turn-detection-and-partials
- Google Cloud `StreamingRecognitionResult`: https://docs.cloud.google.com/speech-to-text/docs/reference/rest/v2/StreamingRecognitionResult
- Azure Speech continuous recognition events: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-recognize-speech
- AWS Transcribe partial-result stabilization: https://docs.aws.amazon.com/transcribe/latest/dg/streaming-partial-results.html
- OpenAI Realtime VAD: https://developers.openai.com/api/docs/guides/realtime-vad
- Whisper-Streaming: https://github.com/ufal/whisper_streaming
- STACL simultaneous translation paper: https://arxiv.org/abs/1810.08398

Downloaded references are stored under `/tmp/livenotes-technical-research` during development. The folder contains local copies from Apple, AWS, Azure, Google, Deepgram, AssemblyAI, and OpenAI. It also contains local checkouts of TypeWhisper and Whisper-Streaming, plus a simultaneous-translation research paper.

## Evaluation Matrix

| Option | Strengths | Risks | Decision |
| --- | --- | --- | --- |
| Apple SpeechAnalyzer live plus final-file pass | Native Swift, on-device, long-form oriented, system-managed model assets, framework-owned audio timeline, supports volatile and final result states. | Requires latest macOS and installed speech assets. Live preview can still be volatile and must not be treated as saved text. | Use for v0.1. |
| Legacy `SFSpeechRecognizer` | Mature API and broad examples. | Weaker fit for long meetings and lectures, older lifecycle, more fragile for long-form local-first transcription. | Reject for v0.1. |
| WhisperKit, whisper.cpp, or MLX Whisper large-v3-turbo | Strong open-source model ecosystem and useful for cross-platform fallback. | Reintroduces model packaging, memory pressure, app size, update, quantization, and runtime QA burden. Prior product goal shifted to pure Swift and native Apple services for this release. | Revisit only if Apple Speech quality is unacceptable in real manual validation. |
| Whisper-Streaming local pipeline | Mature idea for local agreement-based streaming over Whisper models. | More custom buffering and policy code than the current product needs; still needs model/runtime packaging and latency tuning. | Use as design reference, not implementation. |
| Cloud STT providers: Deepgram, AssemblyAI, Google, Azure, AWS | Mature streaming semantics, clear partial/final state models, production examples for endpointing and turn detection. | Violates current local-only product constraint and adds account/network/privacy dependencies. | Use as architecture references only. |
| Apple Translation low-latency strategy | Native Swift, local asset flow, supports batch streaming responses and cancellation. | Language assets may be missing; translation quality must be validated with real English-to-Chinese samples. | Use for v0.1 with preflight availability checks. |
| NLLB, M2M100, or other local translation models | Full local control and potentially broader language coverage. | Adds model packaging and memory pressure; quality and latency need a separate benchmark suite. | Reject for v0.1; keep as fallback research if Apple Translation is insufficient. |
| Prefix-based simultaneous translation | Good research pattern for latency-quality tradeoffs. | Requires partial-sentence translation policy and revision UI. Current UX only needs finalized sentence translation. | Use as future reference, not v0.1 behavior. |

## Architecture Principles From The Research

- Audio buffers are transport units. They are not transcript units, sentence units, or topic units.
- The live UI can show volatile text, but persisted transcript lines must come from final results.
- Save/export should use an authoritative final-file transcription pass, because it has the full audio context and avoids saving temporary live guesses.
- Translation should run on committed final text only. Translating every volatile change creates churn, duplicate work, and unstable UI.
- Turn detection, punctuation, and topic segmentation should sit above stable transcript ranges. They should not be driven by fixed audio chunk duration.
- Timeout and cancellation must be session-generation scoped, so stale translation jobs cannot mutate a saved or replaced transcript.

## Evidence To Implementation Mapping

| Research point | Implementation gate |
| --- | --- |
| Apple SpeechAnalyzer separates volatile and final results. | Core tests verify volatile preview is not saved, and release gates require final-file authority. |
| Apple SpeechAnalyzer can read an `AVAudioFile` directly. | Final transcription uses `analyzeSequence(from: audioFile)` and `finalizeAndFinishThroughEndOfInput()`. |
| Apple SpeechAnalyzer owns the audio timeline. | Live input uses `AnalyzerInput(buffer:)`; release gates reject `bufferStartTime:` in the normal path. |
| Streaming systems expose interim and final states separately. | Live preview remains display-only, while final transcript lines are persisted and translated. |
| Mature endpointing can produce multiple final segments before an utterance is complete. | LiveNotes does not equate any one audio callback with a sentence or topic. |
| Translation APIs can stream batch responses independently. | Production translation uses `translate(batch:)` with stable client identifiers. |
| Translation availability is model-asset dependent. | Before a recording starts on macOS 26.4 or newer, LiveNotes checks English to Simplified Chinese availability with `LanguageAvailability(preferredStrategy: .lowLatency)`. |

## Findings

Apple SpeechAnalyzer is designed around independent async input, async results, and an audio timeline owned by the framework. Apple describes results as either volatile previews or final transcript ranges. Final results are immutable for their audio range.

`SFSpeechErrorDomain` code 2 maps to audio input disorder. That failure fits manual timestamp overlap or non-monotonic input. This is the failure mode LiveNotes hit when it synthesized `bufferStartTime` from fixed-size chunks.

The final-file transcription path should use `SpeechAnalyzer.analyzeSequence(from: AVAudioFile)` and then finish through the end of input. This avoids hand-built file buffer loops and avoids manually assigning `bufferStartTime`.

The live transcription path should feed `AnalyzerInput(buffer:)` through an `AsyncStream`. Live buffers should use framework-inferred timing unless the app intentionally skips audio. The app should not synthesize monotonically increasing timestamps from tap frame counts.

Mature realtime systems do not treat fixed-size audio chunks as user-facing sentences. They maintain separate states for:

- Interim or volatile text that may change.
- Final text that can be persisted and translated.
- Turn or sentence boundaries used for downstream work.

Deepgram separates `is_final` from `speech_final`. Google marks interim results separately from final results. Azure exposes separate recognizing, recognized, stopped, and canceled events. AssemblyAI emits stable partials and final turn events instead of committing every low-level audio chunk.

For LiveNotes, translation should run on final transcript segments only. Volatile text can be displayed, but it should not be saved or exported until finalized.

Apple Translation on the current target SDK provides `LanguageAvailability`, `TranslationError`, `TranslationSession.translate(batch:)`, and `TranslationSession.cancel()`. On the test Mac, English to Simplified Chinese is installed for low-latency translation.

## Decisions

Use this pipeline:

1. Start SpeechAnalyzer before accepting captured audio for live transcription.
2. Capture microphone audio with AVAudioEngine.
3. Copy each accepted tap buffer quickly and move disk write plus live speech feed off the tap callback.
4. Feed live audio through an unbounded or backpressure-aware `AsyncStream<AnalyzerInput>`.
5. Display volatile SpeechAnalyzer results as live preview.
6. Commit only final SpeechAnalyzer results to the session transcript.
7. On stop, finish the live input stream and await SpeechAnalyzer finalization before canceling tasks.
8. Always run final-file transcription from the saved audio file as the authoritative save path.
9. Translate committed final segments with `TranslationSession.translate(batch:)` so responses can be applied as they arrive.
10. Cancel active translation sessions when a final-save timeout is reached, and mark the session generation as canceled so in-flight jobs cannot be requeued after save.
11. Persist enough finalization state to recover unfinished sessions after relaunch.
12. Export through `NSSavePanel`. The panel should start in the last chosen export directory.

## Translation Policy

Use explicit source language `en` and target language `zh-Hans`.

Before recording on macOS 26.4 or newer, check `LanguageAvailability(preferredStrategy: .lowLatency)`:

- `.installed`: enable live translation.
- `.supported`: block recording with a clear instruction to install English and Chinese translation assets before recording.
- `.unsupported`: block recording with a clear message that English to Chinese translation is unavailable on this Mac.

Do not call `prepareTranslation()` with an unknown source language. It can fail before enough source text exists to identify the language.

Use `clientIdentifier` for every translation request. Streaming responses can arrive out of order.

Treat cancellation as session-local. After `TranslationSession.cancel()`, invalidate the SwiftUI translation configuration and wait for a fresh session before submitting new work.

## Rejected Approaches

Rejected: fixed 8-second, 4096-frame, or timer-based user-facing transcript chunks.

Reason: audio buffers are transport units, not semantic units. External STT systems and Apple SpeechAnalyzer separate audio transport from final transcript ranges.

Rejected: manual `bufferStartTime` for normal continuous live audio.

Reason: Apple uses audio timecodes internally. `bufferStartTime` is for skipped audio or explicit timeline control. Manual timestamp synthesis caused fragile behavior and should not be used for the normal continuous path.

Rejected: canceling the live analyzer immediately after closing the input stream.

Reason: finalization is the point where volatile or buffered speech becomes final. Canceling immediately can discard the tail.

Rejected: waiting for whole translation batches before updating any lines.

Reason: the SDK provides `translate(batch:)` as an `AsyncSequence`. That behavior matches the live UI requirement better than all-at-once batch return.

## Regression Gates

Core tests must prove:

- The final-file path uses `analyzeSequence(from: AVAudioFile)`.
- The final-file path does not feed manual file chunks or set `bufferStartTime`.
- Live inputs created from normal continuous audio have `bufferStartTime == nil`.
- Multiple queued live inputs are retained under load.
- Stop drains live finalization instead of returning immediately with an empty tail.
- Tap buffer size is duration-derived from the actual input sample rate and stays within Apple documented tap duration guidance.
- Translation uses streaming batch responses and can apply responses independently.
- Translation timeout cancels the active native translation session and prevents canceled in-flight jobs from being requeued.
- Export starts in the last selected directory.

Manual release validation must prove:

- Fresh Homebrew install launches.
- Microphone permission appears once and recording starts after approval.
- A 30 to 60 second spoken sample creates a saved audio file.
- Live transcript advances during speech.
- Chinese translation appears for finalized English lines.
- Stop saves the final transcript and does not lose the tail.
- Export writes a Markdown file to the selected directory.
