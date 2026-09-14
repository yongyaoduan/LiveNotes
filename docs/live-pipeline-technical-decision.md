# Live Pipeline Technical Decision

Last reviewed: 2026-09-14

## Scope

LiveNotes records microphone audio, shows live English transcription and Chinese translation, and saves the audio with the available text. Export produces a Markdown snapshot and a copy of the recording.

The runtime uses Apple-native recording, Speech, and Translation APIs. Normal stop and export do not run a second transcription pass or require translation completion. Processing recovered audio remains a separate recovery path; later transcription and note processing are outside the normal export path.

## Native Runtime

- `AVAudioEngine` captures microphone audio and `AVAudioFile` stores the recording.
- `SpeechAnalyzer` and `SpeechTranscriber` transcribe English on device with system-managed speech assets.
- Apple Translation provides English-to-Simplified-Chinese translation, using the low-latency strategy on macOS 26.4 or newer.
- Audio buffers are transport units. They do not define sentences or transcript replacement boundaries.

Apple's [SpeechAnalyzer introduction](https://developer.apple.com/videos/play/wwdc2025/277/) covers concurrent audio input and result consumption, audio format conversion, and live transcript presentation. Continuous input uses `AnalyzerInput(buffer:)`; the analyzer owns the audio timeline. Manual timestamps are unnecessary when no audio is skipped.

## Transcript Revisions and Finalization

Keep committed transcript ranges separate from the revisable live preview. A correction may replace text within its source audio range, while unrelated ranges remain intact. Word count is not evidence that one result is more authoritative: a shorter correction can be the final result. Display timestamps must not determine whether two source ranges are the same.

Retain the precise source start time when sorting transcript lines; rounded display seconds can put a retained prefix after its finalized suffix. Older saved sessions without this optional timing field continue to use their existing timestamps. Compare whole words when matching a prefix, and keep attributed text runs together when they divide a word.

[`isFinal`](https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal) describes finality at the time a result is produced. A volatile result is not guaranteed to be sent again with `isFinal == true`.

Use [`resultsFinalizationTime`](https://developer.apple.com/documentation/speech/speechmoduleresult/resultsfinalizationtime) to recognize when earlier results become final without being reissued. Consume each revision and its finalization boundary in result order. Results whose ranges end at or before that boundary are stable; subsequent results cannot revise the earlier finalized audio.

Do not use a separate progress callback to commit pending text ahead of the result consumer. Apple documents that [`setVolatileRangeChangedHandler`](https://developer.apple.com/documentation/speech/speechanalyzer/setvolatilerangechangedhandler(_:)) can report an advanced boundary while older results remain queued. The result's own finalization time avoids that ordering ambiguity.

Preview text may change while recognition improves. Committing a prefix must preserve any remaining preview suffix. Completed transcript lines remain visible and retain their translations as later speech arrives.

A pending hypothesis must not overwrite a finalized correction. Apple can return a coarse temporary phrase with wider timing than its corrected final result. First retain any identifiable prefix/suffix using word timing or exact whole-word matching. When every attributed word of the pending phrase shares its entire coarse range, an attributed final result overlapping more than half of the shorter range replaces that atomic hypothesis, even if many words change. Do not require lexical similarity: short utterances and multiple recognition corrections otherwise leave stale duplicates. Unattributed legacy inputs still use the conservative text-matching fallback. Final boundaries can both shift; tiny overlaps and disjoint repeated speech remain separate. See the [real classroom recording regression](validation-2026-09-14.md).

## Stop, Save, and Export

Normal stop follows this sequence:

1. Stop audio capture and finish writing the recording.
2. Close the live audio input stream and drain the native analyzer's trailing results before canceling its tasks.
3. Save the live transcript and translations already available, without starting full-file recognition or waiting for unfinished translations.

The live analyzer drain is bounded to five seconds. If it cannot finish, retain the available pending tail with low confidence and close the assembly store so late results cannot modify the saved snapshot.

Export takes a snapshot of the selected session, writes its Markdown, and copies its original recording beside it. File operations run away from the main actor. Export neither submits translation jobs nor opens a retry-translation prompt. Duration depends on the amount of audio copied and disk throughput, rather than recognition or translation work.

The source audio remains available for later processing. Recovered audio can be processed through its recovery action. After relaunch, LiveNotes also resumes processing interrupted recordings that have audio but no transcript. This recovery path uses `analyzeSequence(from:)` with an `AVAudioFile`, followed by native finalization. Apple's [file transcription example](https://developer.apple.com/videos/play/wwdc2025/277/?time=321) demonstrates this API. Recovery processing does not run as part of normal stop or export.

## Translation Policy

Use source language `en` and target language `zh-Hans`. Check [`LanguageAvailability`](https://developer.apple.com/documentation/translation/languageavailability) before starting translation; supported languages may still require installed assets.

The live view may show a provisional translation of its current preview. Such a translation can change when the source preview changes. Saved translations belong to committed transcript lines. Keep existing translations when the corresponding source text is unchanged.

Submit committed text through [`TranslationSession.translate(batch:)`](https://developer.apple.com/documentation/translation/translationsession/translate(batch:)) and match responses using stable client identifiers because responses can arrive independently. Cancel or disregard work belonging to an older session generation. Translation completion must not gate normal save or export.

## Open-Source Comparisons

These repositories provide implementation references, not evidence of recognition quality on a particular microphone or recording.

| Reference | Verified behavior | Relevance to LiveNotes |
| --- | --- | --- |
| [arraypress/swift-speech-transcriber](https://github.com/arraypress/swift-speech-transcriber/blob/main/Sources/SpeechTranscriber/Streaming.swift) | Streams audio buffers, exposes text, finality and timing, closes input, finalizes the analyzer, and awaits the result reader. Its [microphone capture](https://github.com/arraypress/swift-speech-transcriber/blob/main/Sources/SpeechTranscriber/MicrophoneCapture.swift) explicitly finishes the input stream when stopped. | A useful small example of native audio transport and draining the tail. Its consumer still needs Apple's finalization-boundary semantics. |
| [DravenYe/swift-speech-analyzer](https://github.com/DravenYe/swift-speech-analyzer/blob/main/transcribe.swift) | Uses `AVAudioEngine`, conversion to the analyzer's format, a revisable terminal preview, and finalization after microphone capture stops. | Demonstrates a direct native microphone pipeline. Terminal display and an `isFinal` check alone do not cover every transcript persistence case. |
| [argmaxinc/apple-speechanalyzer-cli-example](https://github.com/argmaxinc/apple-speechanalyzer-cli-example/blob/main/Sources/apple-speechanalyzer-cli/SpeechAnalyzerCLI.swift) | Reads an audio file through `analyzeSequence(from:)` and writes accumulated text. The checked source uses early SDK preset names and appends all returned results even in its live preset. | A compact file-processing reference. Do not copy its live accumulation policy or obsolete preset names into the app. |

These examples support keeping the native pipeline direct. They do not justify replacing speech models before separating capture failures, transcription accuracy, and application-side text loss in tests.

## Audio Validation

Use complementary checks:

- Feed a known speech recording through the production audio conversion and streaming transcription path at playback speed. Compare the delivered text and saved transcript with the known content. This isolates result handling from the microphone and room acoustics.
- Play a known speech recording through speakers while the app records the microphone. Verify non-silent captured audio, advancing subtitles, retained earlier sentences, the final spoken words, and the exported recording. This exercises the acoustic path, including the active input device and volume.
- Measure export with existing translated text and with missing translations. Confirm no new recognition or translation begins and the app remains responsive during audio copying.

Native system-output capture is also available: Apple's [Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) supports macOS 14.2 or newer and can expose captured process audio through an aggregate device. It requires system audio recording permission and `NSAudioCaptureUsageDescription`. This is a separate capture path and does not prove that the physical microphone works.

[BlackHole](https://github.com/ExistentialAudio/BlackHole) is an optional virtual loopback device for routing another app's output to an input. It is not a LiveNotes runtime dependency. A loopback test and an acoustic microphone test establish different kinds of evidence.

## Regression Requirements

- A shorter final correction replaces its corresponding volatile result.
- Advancing a result's finalization boundary commits earlier unchanged results even when they are not reissued as final.
- Adjacent source ranges both survive even when their displayed whole-second timestamps overlap.
- A committed prefix does not discard the remaining preview or unrelated transcript lines.
- Stopping capture finishes the input stream and retains the final spoken words.
- Normal stop does not invoke full-file recognition or wait for missing translations.
- Export preserves the snapshot's existing text and translations, copies the audio, and performs no recognition or translation.
- An incomplete translation does not block export.
- Audio export does not block the main actor, and failures leave the original recording intact.
- Recovered-audio processing, including automatic recovery of an interrupted recording with no transcript, remains independent of normal stop and export.
