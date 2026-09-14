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
        guard case let .committed(sentence, _) = stableEvents.first else {
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
        guard case let .committed(sentence, _) = stableEvents.first else {
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
        guard case let .committed(sentence, _) = stableEvents.first else {
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

        #expect(duplicate == .none)
        #expect(assembler.previewText.isEmpty)
        #expect(stableEvents.count == 1)
        guard case let .committed(sentence, _) = stableEvents.first else {
            Issue.record("Expected the newer pending correction to commit.")
            return
        }
        #expect(sentence.text == "my name is Joanna.")
        #expect(sentence.startTime == 2)
        #expect(sentence.endTime == 4)
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

        guard case let .committed(sentence, _) = first else {
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

    @Test("speech analyzer accepts a shorter final correction within the same range")
    func speechAnalyzerAcceptsShorterFinalCorrection() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("I I I believe this", start: 0, end: 3))

        _ = await store.apply(speechUpdate("I believe this.", start: 0, end: 3, final: true))

        let sentences = await store.snapshot()
        #expect(sentences.map(\.text) == ["I believe this."])
        #expect(sentences.first?.confidence == .high)
    }

    @Test("speech analyzer accepts equal-length volatile corrections")
    func speechAnalyzerAcceptsEqualLengthVolatileCorrection() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("My name is John.", start: 0, end: 3))

        let events = await store.apply(speechUpdate("My name is Joan.", start: 0, end: 3))
        _ = await store.finish()

        #expect(events.last == .preview("My name is Joan."))
        #expect(await store.snapshot().map(\.text) == ["My name is Joan."])
    }

    @Test("committing one fragment preserves an overlapping pending sentence")
    func committingFragmentPreservesOverlappingPendingSentence() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("First sentence.", start: 0, end: 2.2))
        let combined = await store.apply(speechUpdate(
            "The next sentence has more words.", start: 2.1, end: 5
        ))
        #expect(combined.last == .preview("First sentence. The next sentence has more words."))

        let committed = await store.apply(speechUpdate("First sentence.", start: 0, end: 2.2, final: true))
        #expect(committed.last == .preview("The next sentence has more words."))
        _ = await store.finish()

        #expect(await store.snapshot().map(\.text) == [
            "First sentence.", "The next sentence has more words."
        ])
    }

    @Test("finalizing a prefix retains its pending suffix without duplication")
    func finalizingPrefixRetainsPendingSuffixWithoutDuplication() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("A B C D", start: 0, end: 8))

        let prefixEvents = await store.apply(speechUpdate("A B", start: 0, end: 4, final: true))
        #expect(prefixEvents.last == .preview("C D"))
        #expect(await store.snapshot().map(\.text) == ["A B"])
        _ = await store.apply(speechUpdate("C D", start: 4, end: 8, final: true))
        _ = await store.finish()

        #expect(await store.snapshot().map(\.text) == ["A B", "C D"])
    }

    @Test("finalizing a suffix retains its pending prefix without duplication")
    func finalizingSuffixRetainsPendingPrefixWithoutDuplication() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("A B C D", start: 0, end: 8))

        let suffixEvents = await store.apply(speechUpdate("C D", start: 4, end: 8, final: true))
        #expect(suffixEvents.last == .preview("A B"))
        _ = await store.apply(speechUpdate("A B", start: 0, end: 4, final: true))
        _ = await store.finish()

        #expect(await store.snapshot().map(\.text) == ["A B", "C D"])
    }

    @Test("word timestamps preserve surrounding speech when a final fragment changes wording")
    func wordTimestampsPreserveSurroundingSpeechDuringCorrection() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        var pending = speechUpdate("Before wrong wording after.", start: 0, end: 8)
        pending.fragments = [
            SpeechAnalyzerTranscriptFragment(text: "Before ", startTime: 0, endTime: 2),
            SpeechAnalyzerTranscriptFragment(text: "wrong wording ", startTime: 2, endTime: 6),
            SpeechAnalyzerTranscriptFragment(text: "after.", startTime: 6, endTime: 8)
        ]
        _ = await store.apply(pending)

        let correction = await store.apply(speechUpdate("corrected words", start: 2, end: 6, final: true))
        #expect(correction.last == .preview("Before after."))
        _ = await store.finish()

        #expect(await store.snapshot().map(\.text) == ["Before", "corrected words", "after."])
    }

    @Test("old pending text cannot overwrite a corrected final sentence")
    func oldPendingTextCannotOverwriteCorrectedFinalSentence() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("The secondnd topic is translation. More words follow.", start: 0, end: 8))
        _ = await store.apply(speechUpdate("The second topic is translation.", start: 0, end: 5, final: true))
        _ = await store.finish()

        let sentences = await store.snapshot()
        #expect(sentences.contains { $0.text == "The second topic is translation." && $0.confidence == .high })
    }

    @Test("timed fragments cannot remove characters from inside a word")
    func timedFragmentsCannotRemoveCharactersInsideWord() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        var pending = speechUpdate("Export notes.", start: 0, end: 4)
        pending.fragments = [
            SpeechAnalyzerTranscriptFragment(text: "Ex", startTime: 1, endTime: 2),
            SpeechAnalyzerTranscriptFragment(text: "p", startTime: 0, endTime: 1),
            SpeechAnalyzerTranscriptFragment(text: "ort ", startTime: 2, endTime: 3),
            SpeechAnalyzerTranscriptFragment(text: "notes.", startTime: 3, endTime: 4)
        ]
        _ = await store.apply(pending)
        let events = await store.apply(speechUpdate("An earlier word.", start: 0, end: 1, final: true))
        _ = await store.finish()

        #expect(events.last == .preview("Export notes."))
        #expect(!(await store.snapshot()).contains { $0.text.contains("Exort") })
    }

    @Test("subsecond prefix and suffix keep their source order in snapshots and the session")
    func subsecondPrefixAndSuffixKeepSourceOrder() async throws {
        let assemblyStore = SpeechAnalyzerTranscriptAssemblyStore()
        var sessionStore = SessionStore.clocked(date: Date(timeIntervalSince1970: 2_800))
        let session = sessionStore.createRecording(named: "Lecture")
        _ = await assemblyStore.apply(speechUpdate("The next", start: 0.1, end: 0.9))
        var final = speechUpdate("next", start: 0.5, end: 0.9, final: true)
        final.resultsFinalizationTime = 0.9
        for case let .committed(sentence, replacing) in await assemblyStore.apply(final) {
            try sessionStore.upsertTranscript(in: session.id, sentence: sentence, replacingSentenceIDs: replacing)
        }

        let snapshot = await assemblyStore.snapshot()
        #expect(snapshot.map(\.text) == ["The", "next"])
        #expect(snapshot.map(\.sourceStartTime) == [0.1, 0.5])
        #expect(snapshot.allSatisfy { $0.startTime == 0 && $0.endTime == 1 })
        #expect(sessionStore.session(id: session.id)?.transcript.map(\.text) == ["The", "next"])
    }

    @Test("final words are not suppressed by a longer word with the same characters")
    func finalWordsAreNotSuppressedByCharacterPrefix() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("Theodore is joining", start: 0, end: 2))
        _ = await store.apply(speechUpdate("The", start: 0, end: 0.3, final: true))

        #expect(await store.snapshot().map(\.text) == ["The"])
        #expect(await store.snapshot().first?.confidence == .high)
    }

    @Test("precise sentence ordering supports legacy libraries and survives saving")
    func preciseSentenceOrderingSupportsLegacyLibraries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let legacy = """
        [{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","title":"Lecture","createdAt":"2026-09-05T00:00:00Z","status":{"saved":{"durationSeconds":1}},"transcript":[{"id":"BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE","startTime":0,"endTime":1,"text":"The next","translation":"下一位","confidence":"high"}]}]
        """
        try legacy.write(to: fileStore.url, atomically: true, encoding: .utf8)
        var sessions = try fileStore.load()
        #expect(sessions.first?.transcript.first?.sourceStartTime == nil)
        try fileStore.save(sessions)
        #expect(try fileStore.load() == sessions)

        sessions[0].transcript[0].sourceStartTime = 0.125
        try fileStore.save(sessions)
        #expect(try fileStore.load() == sessions)
        #expect(try fileStore.load().first?.transcript.first?.sourceStartTime == 0.125)
    }

    @Test("native progressive results retain final corrections without stale duplicate sentences", arguments: [
        "native-speech-progressive-results", "native-speech-long-progressive-results",
        "native-speech-acoustic-results"
    ])
    func nativeProgressiveResultsRetainFinalCorrections(_ fixtureName: String) async throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: fixtureName, withExtension: "json", subdirectory: "Fixtures"
        ))
        let results = try JSONDecoder().decode([RecordedSpeechResult].self, from: Data(contentsOf: fixtureURL))
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        for result in results {
            var update = speechUpdate(result.text, start: result.startTime, end: result.endTime, final: result.isFinal)
            update.resultsFinalizationTime = result.resultsFinalizationTime
            update.fragments = result.fragments.map {
                SpeechAnalyzerTranscriptFragment(text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
            }
            _ = await store.apply(update)
        }
        _ = await store.finish()

        let expected = results.filter(\.isFinal).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let actual = await store.snapshot().map(\.text)
        #expect(results.count == (fixtureName.contains("-long-") ? 433 : fixtureName.contains("-acoustic-") ? 143 : 144))
        #expect(actual == expected)
        #expect(!actual.contains { $0.contains("secondnd") || $0.contains("thirdrd") || $0.contains("thirdr ") || $0.contains("Exort") })
    }

    @Test("real fast classroom results retire coarse hypotheses at every final result", arguments: [
        "native-speech-5618-fast-results", "native-speech-5047-fast-results",
        "native-speech-5047-150pct-results", "native-speech-classroom-acoustic-results"
    ])
    func fastClassroomResultsDoNotDuplicateHypotheses(_ fixtureName: String) async throws {
        let url = try #require(Bundle.module.url(forResource: fixtureName, withExtension: "json", subdirectory: "Fixtures"))
        let results = try JSONDecoder().decode([RecordedSpeechResult].self, from: Data(contentsOf: url))
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        var expected: [String] = []
        for result in results {
            var update = speechUpdate(result.text, start: result.startTime, end: result.endTime, final: result.isFinal)
            update.resultsFinalizationTime = result.resultsFinalizationTime
            update.fragments = result.fragments.map { .init(text: $0.text, startTime: $0.startTime, endTime: $0.endTime) }
            let events = await store.apply(update)
            if result.isFinal {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { expected.append(text) }
                #expect(await store.snapshot().map(\.text) == expected)
                #expect(events.last == .preview(""))
            }
        }
        _ = await store.finish()
        #expect(await store.snapshot().map(\.text) == expected)
    }

    @Test("native coarse correction preserves an identifiable unfinished suffix and genuine repetition")
    func nativeCoarseCorrectionPreservesUnfinishedSpeech() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        var pending = speechUpdate("Keep this sentence. More speech follows.", start: 0, end: 8)
        pending.fragments = [.init(text: pending.text, startTime: 0, endTime: 8)]
        _ = await store.apply(pending)
        var final = speechUpdate("Keep this sentence.", start: 0, end: 4, final: true)
        final.fragments = [.init(text: final.text, startTime: 0, endTime: 4)]
        #expect(await store.apply(final).last == .preview("More speech follows."))
        var repeated = speechUpdate("Keep this sentence.", start: 8, end: 12, final: true)
        repeated.fragments = [.init(text: repeated.text, startTime: 8, endTime: 12)]
        _ = await store.apply(repeated)
        _ = await store.finish()
        #expect(await store.snapshot().map(\.text) == ["Keep this sentence.", "More speech follows.", "Keep this sentence."])
    }

    @Test("acoustic coarse hypotheses are replaced when both final boundaries move")
    func acousticCoarseHypothesesWithShiftedBoundaries() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        var pending = speechUpdate("Find", start: 38.64, end: 42.9)
        pending.fragments = [.init(text: pending.text, startTime: pending.startTime, endTime: pending.endTime)]
        _ = await store.apply(pending)
        var final = speechUpdate("Find it, I'll have to set it.", start: 40.08, end: 43.38, final: true)
        final.fragments = [.init(text: final.text, startTime: 40.08, endTime: 43.32)]
        final.resultsFinalizationTime = 43.38
        #expect(await store.apply(final).last == .preview(""))
        _ = await store.finish()
        #expect(await store.snapshot().map(\.text) == [final.text])
    }

    @Test("a small acoustic overlap does not erase a different pending utterance")
    func smallAcousticOverlapPreservesDifferentSpeech() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        var pending = speechUpdate("An earlier sentence.", start: 0, end: 2.2)
        pending.fragments = [.init(text: pending.text, startTime: 0, endTime: 2.2)]
        _ = await store.apply(pending)
        var next = speechUpdate("The next sentence.", start: 2.1, end: 5, final: true)
        next.fragments = [.init(text: next.text, startTime: 2.1, endTime: 5)]
        _ = await store.apply(next)
        _ = await store.finish()
        #expect(await store.snapshot().map(\.text) == [pending.text, next.text])
    }

    @Test("coarse word splitting corrections retain the following sentence")
    func coarseWordSplittingCorrectionsRetainFollowingSentence() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("Please keep the in put stream running.", start: 0, end: 5))
        _ = await store.apply(speechUpdate("The next speaker is ready.", start: 5.1, end: 7))
        var correction = speechUpdate("Please keep the input stream running.", start: 0, end: 4.5, final: true)
        correction.resultsFinalizationTime = 5
        _ = await store.apply(correction)
        _ = await store.finish()

        #expect(await store.snapshot().map(\.text) == [
            "Please keep the input stream running.", "The next speaker is ready."
        ])
    }

    @Test("coarse phrase matching preserves a real unfinished suffix")
    func coarsePhraseMatchingPreservesRealSuffix() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("Please keep every recorded sentence visible. Another person starts talking.", start: 0, end: 7))
        _ = await store.apply(speechUpdate("Please keep every recorded sentence visible.", start: 0, end: 4.5, final: true))
        _ = await store.finish()

        #expect(await store.snapshot().map(\.text) == [
            "Please keep every recorded sentence visible.", "Another person starts talking."
        ])
    }

    @Test("speech analyzer commits corrections before their result finalization boundary")
    func speechAnalyzerUsesOrderedResultFinalizationBoundary() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("The wrong name.", start: 0, end: 2))
        var correction = speechUpdate("The right name.", start: 0, end: 2)
        correction.resultsFinalizationTime = 2

        let events = await store.apply(correction)

        #expect(await store.snapshot().map(\.text) == ["The right name."])
        #expect(events.last == .preview(""))
    }

    @Test("result finalization retains the next pending sentence in the preview")
    func resultFinalizationRetainsNextPendingSentence() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("First sentence.", start: 0, end: 2))
        var next = speechUpdate("Next sentence.", start: 2, end: 4)
        next.resultsFinalizationTime = 2

        let events = await store.apply(next)

        #expect(await store.snapshot().map(\.text) == ["First sentence."])
        #expect(events.last == .preview("Next sentence."))
    }

    @Test("range corrections identify every superseded sentence")
    func rangeCorrectionsIdentifySupersededSentences() async throws {
        let assemblyStore = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await assemblyStore.apply(speechUpdate("Good", start: 0, end: 1, final: true))
        _ = await assemblyStore.apply(speechUpdate("morning", start: 1, end: 2, final: true))
        let originals = await assemblyStore.snapshot()
        var sessionStore = SessionStore.clocked(date: Date(timeIntervalSince1970: 2_800))
        let session = sessionStore.createRecording(named: "Lecture")
        try sessionStore.appendTranscript(to: session.id, sentences: originals)

        let events = await assemblyStore.apply(speechUpdate("Good morning.", start: 0, end: 2, final: true))
        guard case let .committed(sentence, replacing) = events.first else {
            Issue.record("Expected the corrected sentence.")
            return
        }
        try sessionStore.upsertTranscript(
            in: session.id, sentence: sentence, replacingSentenceIDs: replacing
        )

        #expect(Set(replacing) == Set(originals.map(\.id)))
        #expect(sentence.id == originals.first?.id)
        #expect(await assemblyStore.snapshot().map(\.text) == ["Good morning."])
        #expect(sessionStore.session(id: session.id)?.transcript.map(\.text) == ["Good morning."])
    }

    @Test("subsecond speech fragments survive identical displayed timestamps")
    func subsecondFragmentsSurviveIdenticalDisplayedTimestamps() async throws {
        let assemblyStore = SpeechAnalyzerTranscriptAssemblyStore()
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 2_800))
        let session = store.createRecording(named: "Lecture")
        for update in [
            speechUpdate("Yes.", start: 0.1, end: 0.4, final: true),
            speechUpdate("Yes.", start: 0.5, end: 0.9, final: true)
        ] {
            for case let .committed(sentence, replacing) in await assemblyStore.apply(update) {
                try store.upsertTranscript(in: session.id, sentence: sentence, replacingSentenceIDs: replacing)
            }
        }

        let sentences = try #require(store.session(id: session.id)?.transcript)
        #expect(sentences.map(\.text) == ["Yes.", "Yes."])
        #expect(Set(sentences.map(\.id)).count == 2)
        #expect(sentences.allSatisfy { $0.startTime == 0 && $0.endTime == 1 })
    }

    @Test("nearby short audio ranges retain separate recognized words")
    func nearbyShortAudioRangesRetainSeparateRecognizedWords() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("a", start: 0.10, end: 0.13, final: true))
        _ = await store.apply(speechUpdate("new", start: 0.14, end: 0.17, final: true))

        #expect(await store.snapshot().map(\.text) == ["a", "new"])
    }

    @Test("finishing saves pending speech with low confidence and ignores later results")
    func finishingSavesPendingSpeechAndIgnoresLaterResults() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("Completed sentence.", start: 0, end: 2, final: true))
        _ = await store.apply(speechUpdate("The latest unfinished thought", start: 2, end: 5))

        _ = await store.finish()
        let lateEvents = await store.apply(speechUpdate("Unrelated late result.", start: 0, end: 5, final: true))

        let sentences = await store.snapshot()
        #expect(sentences.map(\.text) == ["Completed sentence.", "The latest unfinished thought"])
        #expect(sentences.map(\.confidence) == [.high, .low])
        #expect(lateEvents.isEmpty)
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

    @Test("final transcript segmenter drops punctuation-only speech results")
    func finalTranscriptSegmenterDropsPunctuationOnlySpeechResults() {
        let rawTranscript = [
            transcript(".", start: 7, end: 10),
            transcript("Now we can discuss supervised learning.", start: 9, end: 14)
        ]

        let coalesced = TranscriptUtteranceSegmenter.segment(rawTranscript)

        #expect(coalesced.map(\.text) == [
            "Now we can discuss supervised learning."
        ])
        #expect(coalesced.map(\.startTime) == [9])
        #expect(coalesced.map(\.endTime) == [14])
    }

    @Test("final transcript segmenter merges overlapping short finalized fragments")
    func finalTranscriptSegmenterMergesOverlappingShortFinalizedFragments() {
        let rawTranscript = [
            transcript("Now class.", start: 3, end: 5),
            transcript("Today we discuss supervised learning.", start: 4, end: 10)
        ]

        let coalesced = TranscriptUtteranceSegmenter.segment(rawTranscript)

        #expect(coalesced.map(\.text) == [
            "Now class. Today we discuss supervised learning."
        ])
        #expect(coalesced.map(\.startTime) == [3])
        #expect(coalesced.map(\.endTime) == [10])
    }

    @Test("final transcript segmenter keeps overlapping complete short utterances separate")
    func finalTranscriptSegmenterKeepsOverlappingCompleteShortUtterancesSeparate() {
        let thanks = TranscriptUtteranceSegmenter.segment([
            transcript("Thanks.", start: 0, end: 2),
            transcript("Let's move to neural networks.", start: 1, end: 6)
        ])
        let question = TranscriptUtteranceSegmenter.segment([
            transcript("Any questions?", start: 10, end: 12),
            transcript("We can continue with regression.", start: 11, end: 16)
        ])

        #expect(thanks.map(\.text) == [
            "Thanks.",
            "Let's move to neural networks."
        ])
        #expect(question.map(\.text) == [
            "Any questions?",
            "We can continue with regression."
        ])
    }

    @Test("final transcript segmenter keeps overlapping unspaced sentences separate")
    func finalTranscriptSegmenterKeepsOverlappingUnspacedSentencesSeparate() {
        let rawTranscript = [
            transcript("这是一个完整的中文句子，已经表达了清楚的意思。", start: 0, end: 10),
            transcript("下一句也应该单独保留。", start: 9, end: 14)
        ]

        let coalesced = TranscriptUtteranceSegmenter.segment(rawTranscript)

        #expect(coalesced.map(\.text) == [
            "这是一个完整的中文句子，已经表达了清楚的意思。",
            "下一句也应该单独保留。"
        ])
        #expect(coalesced.map(\.startTime) == [0, 9])
        #expect(coalesced.map(\.endTime) == [10, 14])
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

    @Test("cancelled live startup exits before requesting speech access")
    func cancelledLiveStartupExitsBeforeRequestingSpeechAccess() async {
        let transcriber = NativeSpeechLiveTranscriber()
        let events = LiveAudioHandlerProbe()
        let startTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            try await transcriber.start { _ in events.record() }
        }
        startTask.cancel()

        do {
            try await startTask.value
            Issue.record("Cancelled speech startup must stop before setup.")
        } catch is CancellationError {
        } catch {
            Issue.record("Cancelled speech startup returned an unexpected error: \(error)")
        }

        #expect(events.count == 0)
        #expect(await transcriber.finish().isEmpty)
    }

    @Test("live finish drains committed transcript before timeout")
    func liveFinishDrainsCommittedTranscriptBeforeTimeout() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        let analysisTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let resultTask = Task<[TranscriptSentence], Never> {
            try? await Task.sleep(nanoseconds: 40_000_000)
            _ = await store.apply(speechUpdate("Final transcript.", start: 0, end: 3, final: true))
            return await store.snapshot()
        }

        let transcript = await NativeSpeechLiveTranscriber.drain(
            analysisTask: analysisTask,
            resultTask: resultTask,
            assemblyStore: store,
            timeoutSeconds: 1
        )

        #expect(transcript.map(\.text) == ["Final transcript."])
    }

    @Test("live finish timeout returns before unresponsive analysis completes")
    func liveFinishTimeoutReturnsBeforeAnalysisCompletes() async {
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        _ = await store.apply(speechUpdate("Already saved.", start: 0, end: 2, final: true))
        _ = await store.apply(speechUpdate("Last unfinished words", start: 2, end: 5))
        let analysisTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        let start = ContinuousClock.now

        let sentences = await NativeSpeechLiveTranscriber.drain(
            analysisTask: analysisTask, resultTask: nil, assemblyStore: store, timeoutSeconds: 0.1
        )
        let elapsed = start.duration(to: .now)
        analysisTask.cancel()
        await analysisTask.value

        #expect(elapsed < .seconds(1))
        #expect(sentences.map(\.text) == ["Already saved.", "Last unfinished words"])
        #expect(sentences.map(\.confidence) == [.high, .low])
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

    @Test("microphone authorization reuses granted access across calls and instances")
    func microphoneAuthorizerReusesGrantedAccessAcrossCallsAndInstances() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        for _ in 0..<2 {
            let authorizer = MicrophonePermissionAuthorizer(
                currentState: { .granted },
                requestAccess: { await probe.requestAccess() }
            )

            try await authorizer.authorize()
            try await authorizer.authorize()
        }

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

    @Test("speech recognition authorization reuses granted access across calls and instances")
    func speechRecognitionAuthorizerReusesGrantedAccessAcrossCallsAndInstances() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        for _ in 0..<2 {
            let authorizer = SpeechRecognitionPermissionAuthorizer(
                currentState: { .granted },
                requestAccess: { await probe.requestAccess() }
            )

            try await authorizer.authorize()
            try await authorizer.authorize()
        }

        #expect(await probe.requestCount == 0)
    }

    @Test("speech recognition authorizer does not request denied access")
    func speechRecognitionAuthorizerDoesNotRequestDeniedAccess() async throws {
        let probe = PermissionRequestProbe(grantsAccess: true)
        for _ in 0..<2 {
            let authorizer = SpeechRecognitionPermissionAuthorizer(
                currentState: { .denied },
                requestAccess: { await probe.requestAccess() }
            )

            for _ in 0..<2 {
                do {
                    try await authorizer.authorize()
                    Issue.record("Expected speech recognition access to be denied.")
                } catch let error as RecordingPipelineError {
                    #expect(error.errorDescription == "LiveNotes needs permission to transcribe audio.")
                }
            }
        }

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

    @Test("audio recorder writes non-silent audio from two channel float input")
    func audioRecorderWritesNonSilentAudioFromTwoChannelFloatInput() async throws {
        let directory = try temporaryDirectory()
        let audioURL = directory.appendingPathComponent("fixture.m4a")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
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
        #expect(file.processingFormat.channelCount == 2)
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

private struct RecordedSpeechResult: Decodable {
    struct Fragment: Decodable {
        var text: String
        var startTime: Double
        var endTime: Double
    }

    var text: String
    var startTime: Double
    var endTime: Double
    var isFinal: Bool
    var resultsFinalizationTime: Double
    var fragments: [Fragment]
}

private func speechUpdate(
    _ text: String,
    start: TimeInterval,
    end: TimeInterval,
    final: Bool = false
) -> SpeechAnalyzerTranscriptUpdate {
    SpeechAnalyzerTranscriptUpdate(
        text: text,
        startTime: start,
        endTime: end,
        isFinal: final,
        confidence: final ? .high : .medium
    )
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
