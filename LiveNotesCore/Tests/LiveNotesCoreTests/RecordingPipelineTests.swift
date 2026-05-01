import Foundation
@preconcurrency import AVFoundation
import Speech
import Testing
@testable import LiveNotesCore

@Suite("Recording pipeline")
struct RecordingPipelineTests {
    @Test("readiness report writes release gate keys")
    func readinessReportWritesSnakeCaseKeys() throws {
        let directory = try temporaryDirectory()
        let reportURL = directory.appendingPathComponent("report.json")
        let report = RecordingPipelineReadinessReport(
            audioCapture: "passed",
            speechRecognition: "passed",
            translation: "passed",
            savedTranscript: "passed",
            endToEndRecordingPipeline: "passed",
            processingRuntime: "Apple Speech and Translation",
            metrics: RecordingPipelineMetrics(
                audioDurationSeconds: 2,
                transcriptSegments: 1,
                translationSegments: 1
            )
        )

        try report.write(to: reportURL)
        let data = try Data(contentsOf: reportURL)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try #require(payload["metrics"] as? [String: Any])

        #expect(payload["audio_capture"] as? String == "passed")
        #expect(payload["speech_recognition"] as? String == "passed")
        #expect(payload["translation"] as? String == "passed")
        #expect(payload["saved_transcript"] as? String == "passed")
        #expect(payload["end_to_end_recording_pipeline"] as? String == "passed")
        #expect(payload["processing_runtime"] as? String == "Apple Speech and Translation")
        #expect(metrics["audio_duration_seconds"] as? Double == 2)
        #expect(metrics["transcript_segments"] as? Int == 1)
        #expect(metrics["model_load_seconds"] == nil)
    }

    @Test("live transcript buffer keeps the latest corrected partial")
    func liveTranscriptBufferKeepsLatestPartial() {
        var buffer = LiveTranscriptSegmentBuffer()

        _ = buffer.updatePartial("Hello my name is")
        let latest = buffer.updatePartial("Hello, my name is Yongyao.")
        let final = buffer.finishSegment(endTime: 7)

        #expect(latest == "Hello, my name is Yongyao.")
        #expect(final.map(\.text) == ["Hello, my name is Yongyao."])
        #expect(final.first?.startTime == 0)
        #expect(final.first?.endTime == 7)
        #expect(final.first?.translation == "")
    }

    @Test("live transcript buffer never emits partial word diffs")
    func liveTranscriptBufferNeverEmitsPartialWordDiffs() {
        var buffer = LiveTranscriptSegmentBuffer(startTime: 10)

        _ = buffer.updatePartial("I will talk to you about the social")
        _ = buffer.updatePartial("I will talk to you about the Social Security.")
        let final = buffer.finishSegment(endTime: 18)

        #expect(final.map(\.text) == ["I will talk to you about the Social Security."])
        #expect(final.first?.startTime == 10)
        #expect(final.first?.endTime == 18)
    }

    @Test("live fallback ignores volatile preview text")
    func liveFallbackIgnoresVolatilePreviewText() {
        let existing = [
            TranscriptSentence(
                startTime: 0,
                endTime: 4,
                text: "Hello, my name is today.",
                translation: "",
                confidence: .high
            )
        ]

        let merged = TranscriptCoverage.mergedLiveFallback(
            existing: existing,
            previewText: "Hello, my name is Yong Yao Dun. Today I will talk to you about cybersecurity.",
            previewTranslation: "大家好，我叫段永耀。今天我会讲网络安全。",
            durationSeconds: 12
        )

        #expect(merged.map(\.text) == [
            "Hello, my name is today."
        ])
        #expect(merged.first?.translation == "")
        #expect(merged.first?.endTime == 4)
    }

    @Test("live fallback does not save preview-only tail")
    func liveFallbackDoesNotSavePreviewOnlyTail() {
        let existing = [
            TranscriptSentence(
                startTime: 0,
                endTime: 7,
                text: "I will talk about cybersecurity.",
                translation: "",
                confidence: .high
            )
        ]

        let merged = TranscriptCoverage.mergedLiveFallback(
            existing: existing,
            previewText: "You can fix your problem in your life.",
            previewTranslation: "",
            durationSeconds: 16
        )

        #expect(merged.map(\.text) == [
            "I will talk about cybersecurity."
        ])
        #expect(merged.last?.startTime == 0)
        #expect(merged.last?.endTime == 7)
    }

    @Test("live fallback does not create a transcript from preview only")
    func liveFallbackDoesNotCreateTranscriptFromPreviewOnly() {
        let merged = TranscriptCoverage.mergedLiveFallback(
            existing: [],
            previewText: "This text is still volatile.",
            previewTranslation: "这段文本仍然是临时预览。",
            durationSeconds: 8
        )

        #expect(merged.isEmpty)
    }

    @Test("live fallback clamps committed timestamps to recording duration")
    func liveFallbackClampsCommittedTimestamps() {
        let existing = [
            TranscriptSentence(
                startTime: 45,
                endTime: 134,
                text: "So into it",
                translation: "",
                confidence: .high
            )
        ]

        let merged = TranscriptCoverage.mergedLiveFallback(
            existing: existing,
            previewText: "",
            previewTranslation: "",
            durationSeconds: 52
        )

        #expect(merged.first?.startTime == 45)
        #expect(merged.first?.endTime == 52)
    }

    @Test("speech analyzer assembler commits volatile updates after stable range advances")
    func speechAnalyzerAssemblerCommitsVolatileUpdatesAfterStableRangeAdvances() {
        var assembler = SpeechAnalyzerTranscriptAssembler()

        let event = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone, my name is",
                startTime: 0,
                endTime: 2.4,
                isFinal: false,
                confidence: .medium
            )
        )

        #expect(event == .preview("Hello everyone, my name is"))
        let stableEvents = assembler.advanceStableBoundary(to: 3)
        guard case let .committed(sentence) = stableEvents.first else {
            Issue.record("Expected a committed sentence.")
            return
        }
        #expect(stableEvents.count == 1)
        #expect(sentence.startTime == 0)
        #expect(sentence.endTime == 3)
        #expect(sentence.text == "Hello everyone, my name is")
        #expect(sentence.confidence == .medium)
    }

    @Test("speech analyzer assembler commits latest overlapping volatile update")
    func speechAnalyzerAssemblerCommitsLatestOverlappingVolatileUpdate() {
        var assembler = SpeechAnalyzerTranscriptAssembler()

        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello",
                startTime: 0,
                endTime: 1,
                isFinal: false,
                confidence: .medium
            )
        )
        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone, my name is",
                startTime: 0,
                endTime: 3,
                isFinal: false,
                confidence: .medium
            )
        )

        let stableEvents = assembler.advanceStableBoundary(to: 4)

        #expect(stableEvents.count == 1)
        guard case let .committed(sentence) = stableEvents.first else {
            Issue.record("Expected a committed sentence.")
            return
        }
        #expect(sentence.text == "Hello everyone, my name is")
    }

    @Test("speech analyzer assembler keeps longer pending update over contained volatile update")
    func speechAnalyzerAssemblerKeepsLongerPendingUpdateOverContainedVolatileUpdate() {
        var assembler = SpeechAnalyzerTranscriptAssembler()

        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone, my name is",
                startTime: 0,
                endTime: 3,
                isFinal: false,
                confidence: .medium
            )
        )
        let preview = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello",
                startTime: 0,
                endTime: 1,
                isFinal: false,
                confidence: .medium
            )
        )
        let stableEvents = assembler.advanceStableBoundary(to: 4)

        #expect(preview == .preview("Hello everyone, my name is"))
        #expect(stableEvents.count == 1)
        guard case let .committed(sentence) = stableEvents.first else {
            Issue.record("Expected a committed sentence.")
            return
        }
        #expect(sentence.text == "Hello everyone, my name is")
    }

    @Test("speech analyzer assembler does not duplicate overlapping final update after stable commit")
    func speechAnalyzerAssemblerDoesNotDuplicateOverlappingFinalUpdateAfterStableCommit() {
        var assembler = SpeechAnalyzerTranscriptAssembler()

        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone",
                startTime: 0,
                endTime: 2,
                isFinal: false,
                confidence: .medium
            )
        )
        _ = assembler.advanceStableBoundary(to: 3)
        let duplicate = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello",
                startTime: 0,
                endTime: 1,
                isFinal: true,
                confidence: .high
            )
        )

        #expect(duplicate == .none)
    }

    @Test("speech analyzer assembler keeps committed range after duplicate final update")
    func speechAnalyzerAssemblerKeepsCommittedRangeAfterDuplicateFinalUpdate() {
        var assembler = SpeechAnalyzerTranscriptAssembler()

        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone.",
                startTime: 0,
                endTime: 2,
                isFinal: false,
                confidence: .medium
            )
        )
        _ = assembler.advanceStableBoundary(to: 3)
        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone.",
                startTime: 0,
                endTime: 2,
                isFinal: true,
                confidence: .high
            )
        )
        let containedFinal = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello",
                startTime: 0,
                endTime: 1,
                isFinal: true,
                confidence: .high
            )
        )

        #expect(containedFinal == .none)
    }

    @Test("speech analyzer assembler keeps newer pending correction after duplicate final update")
    func speechAnalyzerAssemblerKeepsNewerPendingCorrectionAfterDuplicateFinalUpdate() {
        var assembler = SpeechAnalyzerTranscriptAssembler()

        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone.",
                startTime: 0,
                endTime: 2,
                isFinal: false,
                confidence: .medium
            )
        )
        _ = assembler.advanceStableBoundary(to: 3)
        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone, my name is Joanna.",
                startTime: 0,
                endTime: 4,
                isFinal: false,
                confidence: .medium
            )
        )
        let duplicate = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone.",
                startTime: 0,
                endTime: 2,
                isFinal: true,
                confidence: .high
            )
        )
        let stableEvents = assembler.advanceStableBoundary(to: 5)

        #expect(duplicate == .preview("Hello everyone, my name is Joanna."))
        #expect(stableEvents.count == 1)
        guard case let .committed(sentence) = stableEvents.first else {
            Issue.record("Expected the newer pending correction to commit.")
            return
        }
        #expect(sentence.text == "Hello everyone, my name is Joanna.")
    }

    @Test("speech analyzer assembler commits final updates once")
    func speechAnalyzerAssemblerCommitsFinalUpdatesOnce() {
        var assembler = SpeechAnalyzerTranscriptAssembler()

        _ = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone, my name is",
                startTime: 0,
                endTime: 2.4,
                isFinal: false,
                confidence: .medium
            )
        )
        let first = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone, my name is Joanna.",
                startTime: 0,
                endTime: 3.8,
                isFinal: true,
                confidence: .high
            )
        )
        let duplicate = assembler.apply(
            SpeechAnalyzerTranscriptUpdate(
                text: "Hello everyone, my name is Joanna.",
                startTime: 0,
                endTime: 3.8,
                isFinal: true,
                confidence: .high
            )
        )

        guard case let .committed(sentence) = first else {
            Issue.record("Expected a committed sentence.")
            return
        }
        #expect(sentence.startTime == 0)
        #expect(sentence.endTime == 4)
        #expect(sentence.text == "Hello everyone, my name is Joanna.")
        #expect(sentence.translation == "")
        #expect(sentence.confidence == .high)
        #expect(duplicate == .none)
    }

    @Test("final transcript segmenter merges phrase-level speech results into readable utterances")
    func finalTranscriptSegmenterMergesPhraseLevelSpeechResults() {
        let rawTranscript = [
            transcript("Hello? My name is", start: 3, end: 5),
            transcript("Yum Yardo.", start: 5, end: 6),
            transcript("And I", start: 6, end: 7),
            transcript("will talk to you about", start: 7, end: 8),
            transcript("the assignment.", start: 8, end: 9),
            transcript("I", start: 9, end: 10),
            transcript("know the", start: 10, end: 11),
            transcript("assignment is", start: 11, end: 12),
            transcript("overdue, so", start: 12, end: 13),
            transcript("I will talk to you about", start: 13, end: 15),
            transcript("the another", start: 15, end: 16),
            transcript("concept.", start: 16, end: 17),
            transcript("Like, this", start: 17, end: 19),
            transcript("concept is", start: 19, end: 20),
            transcript("about the cybersecurity.", start: 20, end: 21)
        ]

        let coalesced = TranscriptUtteranceSegmenter.segment(rawTranscript)

        #expect(coalesced.map(\.text) == [
            "Hello? My name is Yum Yardo.",
            "And I will talk to you about the assignment.",
            "I know the assignment is overdue, so I will talk to you about the another concept.",
            "Like, this concept is about the cybersecurity."
        ])
        #expect(coalesced.map(\.startTime) == [3, 6, 9, 17])
        #expect(coalesced.map(\.endTime) == [6, 9, 17, 21])
    }

    @Test("final transcript segmenter keeps long pauses as utterance boundaries")
    func finalTranscriptSegmenterKeepsLongPausesAsSegmentBoundaries() {
        let rawTranscript = [
            transcript("This concept is about structured data", start: 0, end: 4),
            transcript("and abstract data", start: 4, end: 6),
            transcript("After that", start: 10, end: 11),
            transcript("you can use it for machine learning.", start: 11, end: 14)
        ]

        let coalesced = TranscriptUtteranceSegmenter.segment(rawTranscript)

        #expect(coalesced.map(\.text) == [
            "This concept is about structured data and abstract data",
            "After that you can use it for machine learning."
        ])
        #expect(coalesced.map(\.startTime) == [0, 10])
        #expect(coalesced.map(\.endTime) == [6, 14])
    }

    @Test("preserved translation segmenter keeps translated and pending fragments separate")
    func preservedTranslationSegmenterKeepsTranslatedAndPendingFragmentsSeparate() {
        var translated = transcript("Okay.", start: 0, end: 1)
        translated.translation = "好的。"
        let pending = transcript("Now we can continue.", start: 1, end: 4)

        let coalesced = TranscriptUtteranceSegmenter.segment(
            [translated, pending],
            translationMode: .preserveMergedTranslations
        )

        #expect(coalesced.map(\.text) == ["Okay.", "Now we can continue."])
        #expect(coalesced.map(\.translation) == ["好的。", ""])
    }

    @Test("finalization policy keeps live transcript when generated transcript loses coverage")
    func finalizationPolicyKeepsLiveTranscriptWhenGeneratedTranscriptLosesCoverage() {
        let live = [
            transcript("Hello everyone, my name is Joanna.", start: 0, end: 4),
            transcript("Today I will talk about social security.", start: 4, end: 9),
            transcript("Then we will move to another topic.", start: 9, end: 14)
        ]
        let generated = [
            transcript("Security.", start: 4, end: 5)
        ]

        let chosen = TranscriptFinalizationPolicy.chooseTranscript(
            generated: generated,
            live: live
        )

        #expect(chosen.map(\.text) == live.map(\.text))
    }

    @Test("finalization policy uses generated transcript when live transcript is empty")
    func finalizationPolicyUsesGeneratedTranscriptWhenLiveTranscriptIsEmpty() {
        let generated = [
            transcript("The final pass found the complete sentence.", start: 0, end: 5)
        ]

        let chosen = TranscriptFinalizationPolicy.chooseTranscript(
            generated: generated,
            live: []
        )

        #expect(chosen.map(\.text) == generated.map(\.text))
    }

    @Test("audio level meter reports normalized speech activity")
    func audioLevelMeterReportsNormalizedSpeechActivity() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try sineWaveBuffer(format: format, durationSeconds: 0.25)

        let level = AudioLevelMeter.normalizedLevel(for: buffer)

        #expect(level > 0.15)
        #expect(level <= 1.0)
    }

    @Test("audio level meter treats silence as no activity")
    func audioLevelMeterTreatsSilenceAsNoActivity() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try silentBuffer(format: format, durationSeconds: 0.25)

        #expect(AudioLevelMeter.normalizedLevel(for: buffer) == 0)
    }

    @Test("speech analyzer audio converter produces compatible PCM")
    func speechAnalyzerAudioConverterProducesCompatiblePCM() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try sineWaveBuffer(format: sourceFormat, durationSeconds: 0.25)

        let converted = try #require(SpeechAnalyzerAudioConverter.convert(source, to: targetFormat))

        #expect(converted.format.sampleRate == targetFormat.sampleRate)
        #expect(converted.format.channelCount == targetFormat.channelCount)
        #expect(converted.frameLength > 0)
        #expect(AudioLevelMeter.normalizedLevel(for: converted) > 0.05)
    }

    @Test("speech analyzer live input converter lets the framework infer contiguous timing")
    func speechAnalyzerLiveInputConverterInfersContiguousTiming() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try sineWaveBuffer(format: sourceFormat, durationSeconds: 0.25)
        let converter = SpeechAnalyzerLiveInputConverter(targetFormat: targetFormat)

        let input = try #require(converter.input(from: source))

        #expect(input.buffer.format.sampleRate == targetFormat.sampleRate)
        #expect(input.buffer.format.channelCount == targetFormat.channelCount)
        #expect(input.buffer.frameLength > 0)
        #expect(input.bufferStartTime == nil)
    }

    @Test("speech analyzer live input converter keeps consecutive buffers untimestamped")
    func speechAnalyzerLiveInputConverterKeepsConsecutiveBuffersUntimestamped() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffers = try (0..<3).map { _ in
            try sineWaveBuffer(format: sourceFormat, durationSeconds: 4_096 / 48_000)
        }

        let converter = SpeechAnalyzerLiveInputConverter(targetFormat: targetFormat)
        var inputs: [AnalyzerInput] = []
        for buffer in buffers {
            if let input = converter.input(from: buffer) {
                inputs.append(input)
            }
        }

        #expect(inputs.count == 3)
        #expect(inputs.allSatisfy { $0.bufferStartTime == nil })
        #expect(inputs.allSatisfy { $0.buffer.frameLength > 0 })
    }

    @Test("audio tap buffer size follows Apple duration guidance")
    func audioTapBufferSizeFollowsAppleDurationGuidance() {
        #expect(AudioTapBufferSize.frameCount(sampleRate: 48_000) == 9_600)
        #expect(AudioTapBufferSize.frameCount(sampleRate: 44_100) == 8_820)
        #expect(AudioTapBufferSize.frameCount(sampleRate: 16_000) == 3_200)
    }

    @Test("speech analyzer input pipe retains queued live audio")
    func speechAnalyzerInputPipeRetainsQueuedLiveAudio() async throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let pipe = SpeechAnalyzerInputPipe()

        for _ in 0..<300 {
            pipe.yield(AnalyzerInput(buffer: buffer))
        }
        pipe.finish()

        var count = 0
        for await _ in pipe.stream {
            count += 1
        }

        #expect(count == 300)
    }

    @Test("live finish drains committed transcript before timeout")
    func liveFinishDrainsCommittedTranscriptBeforeTimeout() async {
        let store = LiveTranscriptCommitStore()
        let sentence = TranscriptSentence(
            startTime: 0,
            endTime: 3,
            text: "Final transcript.",
            translation: "",
            confidence: .high
        )
        let analysisTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let resultTask = Task<[TranscriptSentence], Never> {
            try? await Task.sleep(nanoseconds: 40_000_000)
            await store.append(sentence)
            return await store.snapshot()
        }

        let transcript = await NativeSpeechLiveTranscriber.drain(
            analysisTask: analysisTask,
            resultTask: resultTask,
            commitStore: store,
            timeoutSeconds: 1
        )

        #expect(transcript.map(\.text) == ["Final transcript."])
    }

    @Test("final transcription uses SpeechAnalyzer file input")
    func finalTranscriptionUsesSpeechAnalyzerFileInput() throws {
        let source = try recordingPipelineSource()
        guard let functionRange = source.range(of: "private static func transcribeWithSpeechAnalyzer") else {
            Issue.record("Final transcription function is missing.")
            return
        }
        let functionSource = String(source[functionRange.lowerBound...])

        #expect(functionSource.contains("try await analyzer.analyzeSequence(from: audioFile)"))
        #expect(functionSource.contains("try await analyzer.finalizeAndFinishThroughEndOfInput()"))
        #expect(!functionSource.contains("bufferStartTime:"))
    }

    @Test("microphone authorizer requests undetermined access")
    func microphoneAuthorizerRequestsUndeterminedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        let authorizer = MicrophonePermissionAuthorizer(
            currentState: { .undetermined },
            requestAccess: { await probe.requestAccess() }
        )

        try await authorizer.authorize()

        #expect(await probe.requestCount == 1)
    }

    @Test("microphone authorizer rejects denied undetermined access")
    func microphoneAuthorizerRejectsDeniedUndeterminedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: false)
        let authorizer = MicrophonePermissionAuthorizer(
            currentState: { .undetermined },
            requestAccess: { await probe.requestAccess() }
        )

        do {
            try await authorizer.authorize()
            Issue.record("Expected microphone access to be denied.")
        } catch let error as RecordingPipelineError {
            #expect(error.errorDescription == "Microphone access is required to record audio.")
        }

        #expect(await probe.requestCount == 1)
    }

    @Test("microphone authorizer does not request granted access")
    func microphoneAuthorizerDoesNotRequestGrantedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        let authorizer = MicrophonePermissionAuthorizer(
            currentState: { .granted },
            requestAccess: { await probe.requestAccess() }
        )

        try await authorizer.authorize()

        #expect(await probe.requestCount == 0)
    }

    @Test("microphone authorizer does not request denied access")
    func microphoneAuthorizerDoesNotRequestDeniedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        let authorizer = MicrophonePermissionAuthorizer(
            currentState: { .denied },
            requestAccess: { await probe.requestAccess() }
        )

        do {
            try await authorizer.authorize()
            Issue.record("Expected microphone access to be denied.")
        } catch let error as RecordingPipelineError {
            #expect(error.errorDescription == "Microphone access is required to record audio.")
        }

        #expect(await probe.requestCount == 0)
    }

    @Test("speech recognition authorizer requests undetermined access")
    func speechRecognitionAuthorizerRequestsUndeterminedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        let authorizer = SpeechRecognitionPermissionAuthorizer(
            currentState: { .undetermined },
            requestAccess: { await probe.requestAccess() }
        )

        try await authorizer.authorize()

        #expect(await probe.requestCount == 1)
    }

    @Test("speech recognition authorizer rejects denied undetermined access")
    func speechRecognitionAuthorizerRejectsDeniedUndeterminedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: false)
        let authorizer = SpeechRecognitionPermissionAuthorizer(
            currentState: { .undetermined },
            requestAccess: { await probe.requestAccess() }
        )

        do {
            try await authorizer.authorize()
            Issue.record("Expected speech recognition access to be denied.")
        } catch let error as RecordingPipelineError {
            #expect(error.errorDescription == "LiveNotes needs permission to transcribe audio.")
        }

        #expect(await probe.requestCount == 1)
    }

    @Test("speech recognition authorizer does not request granted access")
    func speechRecognitionAuthorizerDoesNotRequestGrantedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        let authorizer = SpeechRecognitionPermissionAuthorizer(
            currentState: { .granted },
            requestAccess: { await probe.requestAccess() }
        )

        try await authorizer.authorize()

        #expect(await probe.requestCount == 0)
    }

    @Test("audio recorder rejects denied microphone access before creating output")
    func audioRecorderRejectsDeniedMicrophoneAccessBeforeCreatingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audioURL = directory.appendingPathComponent("denied.m4a")
        let recorder = AVAudioRecordingEngine(
            microphonePermissionAuthorizer: MicrophonePermissionAuthorizer(
                currentState: { .denied },
                requestAccess: { true }
            )
        )

        do {
            try await recorder.startRecording(to: audioURL)
            Issue.record("Expected microphone access to be denied.")
        } catch let error as RecordingPipelineError {
            #expect(error.errorDescription == "Microphone access is required to record audio.")
        }

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test("audio recorder defers audio engine construction until recording starts")
    func audioRecorderDefersAudioEngineConstructionUntilRecordingStarts() {
        let probe = AudioEngineFactoryProbe()

        _ = AVAudioRecordingEngine(
            microphonePermissionAuthorizer: .preflightGranted,
            audioInputProviderFactory: {
                probe.makeProvider()
            }
        )

        #expect(probe.makeCount == 0)
    }

    @Test("audio recorder writes a decodable audio file from fixture PCM")
    func audioRecorderWritesDecodableAudioFileFromFixturePCM() async throws {
        let directory = try temporaryDirectory()
        let audioURL = directory.appendingPathComponent("fixture.m4a")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let provider = FixtureAudioInputProvider(
            format: format,
            buffers: [try sineWaveBuffer(format: format, durationSeconds: 1.0)]
        )
        let recorder = AVAudioRecordingEngine(
            microphonePermissionAuthorizer: .preflightGranted,
            audioInputProviderFactory: { provider }
        )

        try await recorder.startRecording(to: audioURL)
        let durationSeconds = try recorder.stopRecording()

        #expect(durationSeconds == 1)
        let file = try AVAudioFile(forReading: audioURL)
        #expect(file.length > 0)
        #expect(file.processingFormat.channelCount == 1)
        #expect(Int(file.processingFormat.sampleRate.rounded()) == 16_000)
        #expect(try rmsLevel(for: file) > 0.01)
    }

    @Test("audio recorder writes non-silent audio from Int16 PCM input")
    func audioRecorderWritesNonSilentAudioFromInt16PCMInput() async throws {
        let directory = try temporaryDirectory()
        let audioURL = directory.appendingPathComponent("fixture.m4a")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let provider = FixtureAudioInputProvider(
            format: format,
            buffers: [try int16SineWaveBuffer(format: format, durationSeconds: 1.0)]
        )
        let recorder = AVAudioRecordingEngine(
            microphonePermissionAuthorizer: .preflightGranted,
            audioInputProviderFactory: { provider }
        )

        try await recorder.startRecording(to: audioURL)
        let durationSeconds = try recorder.stopRecording()

        #expect(durationSeconds == 1)
        let file = try AVAudioFile(forReading: audioURL)
        #expect(file.length > 0)
        #expect(file.processingFormat.channelCount == 1)
        #expect(Int(file.processingFormat.sampleRate.rounded()) == 48_000)
        #expect(try rmsLevel(for: file) > 0.01)
    }

    @Test("audio recorder processes accepted buffers off the capture callback")
    func audioRecorderProcessesAcceptedBuffersOffCaptureCallback() async throws {
        let directory = try temporaryDirectory()
        let audioURL = directory.appendingPathComponent("fixture.m4a")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let provider = FixtureAudioInputProvider(
            format: format,
            buffers: [try sineWaveBuffer(format: format, durationSeconds: 1.0)]
        )
        let processingQueue = DispatchQueue(label: "app.livenotes.tests.buffer-processing")
        processingQueue.suspend()
        var queueIsSuspended = true
        defer {
            if queueIsSuspended {
                processingQueue.resume()
            }
        }
        let liveProbe = LiveAudioHandlerProbe()
        let recorder = AVAudioRecordingEngine(
            microphonePermissionAuthorizer: .preflightGranted,
            liveAudioHandler: { _ in
                liveProbe.record()
            },
            audioInputProviderFactory: { provider },
            bufferProcessingQueue: processingQueue
        )

        try await recorder.startRecording(to: audioURL)

        #expect(liveProbe.count == 0)
        processingQueue.resume()
        queueIsSuspended = false
        #expect(liveProbe.waitForCount(1, timeoutSeconds: 2))
        let durationSeconds = try recorder.stopRecording()

        #expect(durationSeconds == 1)
        let file = try AVAudioFile(forReading: audioURL)
        #expect(file.length > 0)
    }

    @Test("audio fixture writer creates decodable non-silent audio")
    func audioFixtureWriterCreatesDecodableNonSilentAudio() throws {
        let directory = try temporaryDirectory()
        let audioURL = directory.appendingPathComponent("fixture.m4a")

        try AudioFixtureWriter.writeSineWaveM4A(to: audioURL, durationSeconds: 1)

        let file = try AVAudioFile(forReading: audioURL)
        #expect(file.length > 0)
        #expect(file.processingFormat.channelCount == 1)
        #expect(Int(file.processingFormat.sampleRate.rounded()) == 16_000)
        #expect(try rmsLevel(for: file) > 0.01)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recordingPipelineSource() throws -> String {
        let testURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("LiveNotesCore")
            .appendingPathComponent("RecordingPipeline.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private func transcript(_ text: String, start: Int, end: Int) -> TranscriptSentence {
    TranscriptSentence(
        startTime: start,
        endTime: end,
        text: text,
        translation: "",
        confidence: .high
    )
}

private final class LiveAudioHandlerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var recordedCount = 0

    var count: Int {
        lock.withLock { recordedCount }
    }

    func record() {
        lock.withLock {
            recordedCount += 1
        }
        semaphore.signal()
    }

    func waitForCount(_ target: Int, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while count < target {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            if semaphore.wait(timeout: .now() + remaining) == .timedOut {
                return count >= target
            }
        }
        return true
    }
}

private actor PermissionRequestProbe {
    private(set) var requestCount = 0
    private let grantsAccess: Bool

    init(grantsAccess: Bool) {
        self.grantsAccess = grantsAccess
    }

    func requestAccess() -> Bool {
        requestCount += 1
        return grantsAccess
    }
}

private final class AudioEngineFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var makeCount: Int {
        lock.withLock { count }
    }

    func makeProvider() -> AudioInputProviding {
        lock.withLock {
            count += 1
        }
        return FixtureAudioInputProvider(
            format: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )!,
            buffers: []
        )
    }
}

private final class FixtureAudioInputProvider: AudioInputProviding, @unchecked Sendable {
    private let format: AVAudioFormat
    private let buffers: [AVAudioPCMBuffer]

    init(format: AVAudioFormat, buffers: [AVAudioPCMBuffer]) {
        self.format = format
        self.buffers = buffers
    }

    func outputFormat() throws -> AVAudioFormat {
        format
    }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        for buffer in buffers {
            bufferHandler(buffer)
        }
    }

    func stop() {}
}

private func sineWaveBuffer(
    format: AVAudioFormat,
    durationSeconds: Double
) throws -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(format.sampleRate * durationSeconds)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    let channel = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
        channel[frame] = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / format.sampleRate) * 0.35)
    }
    return buffer
}

private func int16SineWaveBuffer(
    format: AVAudioFormat,
    durationSeconds: Double
) throws -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(format.sampleRate * durationSeconds)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    let channel = try #require(buffer.int16ChannelData?[0])
    for frame in 0..<Int(frameCount) {
        let sample = sin(2.0 * Double.pi * 440.0 * Double(frame) / format.sampleRate)
        channel[frame] = Int16(sample * 0.35 * Double(Int16.max))
    }
    return buffer
}

private func silentBuffer(
    format: AVAudioFormat,
    durationSeconds: Double
) throws -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(format.sampleRate * durationSeconds)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    return buffer
}

private func rmsLevel(for file: AVAudioFile) throws -> Float {
    let frameCount = AVAudioFrameCount(file.length)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: frameCount
    ))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    let frames = max(1, Int(buffer.frameLength))
    var sumSquares: Float = 0
    for frame in 0..<frames {
        sumSquares += channel[frame] * channel[frame]
    }
    return sqrt(sumSquares / Float(frames))
}
