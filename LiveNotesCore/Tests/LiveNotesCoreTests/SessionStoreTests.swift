import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Session store")
struct SessionStoreTests {
    @Test("new recording creates a preparing session at the top of the sidebar")
    func newRecordingCreatesPreparingSession() {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 1_800))

        let session = store.createRecording(
            named: "Untitled Recording",
            audioFileName: "Audio/example.m4a"
        )

        #expect(store.sessions.first?.id == session.id)
        #expect(store.sessions.first?.title == "Untitled Recording")
        #expect(store.sessions.first?.status == .preparing)
        #expect(store.sessions.first?.audioFileName == "Audio/example.m4a")
        #expect(store.selectedSessionID == session.id)
    }

    @Test("session status follows the recording lifecycle")
    func recordingLifecycle() throws {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 2_400))
        let session = store.createRecording(named: "Neural Networks")

        try store.startRecording(session.id, elapsedSeconds: 12)
        #expect(store.session(id: session.id)?.status == .recording(elapsedSeconds: 12))

        try store.startRecording(session.id)
        #expect(store.session(id: session.id)?.status == .recording(elapsedSeconds: 0))

        try store.pauseRecording(session.id, elapsedSeconds: 908)
        #expect(store.session(id: session.id)?.status == .paused(elapsedSeconds: 908))

        try store.finalizeRecording(session.id, progress: 0.62)
        #expect(store.session(id: session.id)?.status == .finalizing(progress: 0.62))

        try store.finalizeRecording(session.id, progress: 1.0)
        #expect(store.session(id: session.id)?.status.label == "Ready to review")

        try store.saveRecording(
            session.id,
            durationSeconds: 3_120,
            audioFileName: "Audio/neural-networks.m4a"
        )
        #expect(store.session(id: session.id)?.status == .saved(durationSeconds: 3_120))
        #expect(store.session(id: session.id)?.audioFileName == "Audio/neural-networks.m4a")
    }

    @Test("saved session keeps transcript, translations, topics, and audio anchors")
    func savedSessionKeepsCoreContent() throws {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 3_000))
        let session = store.createRecording(named: "Neural Networks")

        try store.appendTranscript(
            to: session.id,
            sentence: TranscriptSentence(
                startTime: 883,
                endTime: 895,
                text: "Activation functions turn linear outputs into useful signals.",
                translation: TestText.activationFunctionTranslation,
                confidence: .high
            )
        )
        try store.upsertTopic(
            in: session.id,
            topic: TopicNote(
                title: "Activation Functions",
                startTime: 883,
                endTime: nil,
                summary: "Activation functions add non-linearity to model outputs.",
                keyPoints: [
                    "They transform linear outputs.",
                    "They make deeper models useful."
                ],
                questions: [
                    "Why does non-linearity matter?"
                ]
            )
        )

        let saved = try #require(store.session(id: session.id))
        #expect(saved.transcript.count == 1)
        #expect(saved.transcript.first?.translation == TestText.activationFunctionTranslation)
        #expect(saved.topics.first?.title == "Activation Functions")
        #expect(saved.topics.first?.keyPoints.count == 2)
    }

    @Test("generated transcript and topics replace processing placeholders")
    func generatedContentReplacesPlaceholders() throws {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 3_300))
        let session = store.createRecording(named: "Planning")
        let transcript = [
            TranscriptSentence(
                startTime: 0,
                endTime: 3,
                text: "We need a follow-up.",
                translation: TestText.customerFollowUpTranslation,
                confidence: .high
            )
        ]
        let topics = [
            TopicNote(
                title: "Follow-up",
                startTime: 0,
                endTime: 3,
                summary: "The session identifies a follow-up.",
                keyPoints: ["A follow-up is required."],
                questions: []
            )
        ]

        try store.replaceGeneratedContent(in: session.id, transcript: transcript, topics: topics)

        #expect(store.session(id: session.id)?.transcript == transcript)
        #expect(store.session(id: session.id)?.topics == topics)
    }

    @Test("failed recording keeps the session visible")
    func failedRecordingKeepsSessionVisible() throws {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 3_600))
        let session = store.createRecording(named: "Planning")

        try store.failRecording(session.id, message: "Microphone access was interrupted.")

        #expect(store.session(id: session.id)?.status == .failed(message: "Microphone access was interrupted."))
    }

    @Test("recovered audio appears as a sidebar session")
    func recoveredAudioAppearsInSidebar() {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 4_200))

        let recovered = store.recoverAudio(
            title: "Recovered Audio",
            durationSeconds: 2_280,
            lastSavedAt: Date(timeIntervalSince1970: 4_000),
            audioFileName: "Audio/recovered.m4a"
        )

        #expect(store.sessions.first?.id == recovered.id)
        #expect(store.sessions.first?.status == .recovered(durationSeconds: 2_280))
        #expect(store.sessions.first?.audioFileName == "Audio/recovered.m4a")
        #expect(store.selectedSessionID == recovered.id)
    }

    @Test("interrupted sessions recover on next launch")
    func interruptedSessionsRecoverOnNextLaunch() throws {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 4_800))
        let recording = store.createRecording(named: "Active", audioFileName: "Audio/active.m4a")
        try store.startRecording(recording.id, elapsedSeconds: 90)
        let finalizing = store.createRecording(named: "Finalizing", audioFileName: "Audio/finalizing.m4a")
        try store.appendTranscript(
            to: finalizing.id,
            sentence: TranscriptSentence(
                startTime: 0,
                endTime: 120,
                text: "Recovered transcript.",
                translation: TestText.customerFollowUpTranslation,
                confidence: .high
            )
        )
        try store.finalizeRecording(finalizing.id, progress: 0.5)
        let saved = store.createRecording(named: "Saved", audioFileName: "Audio/saved.m4a")
        try store.saveRecording(saved.id, durationSeconds: 60, audioFileName: "Audio/saved.m4a")

        let recoveredCount = store.recoverInterruptedSessions()

        #expect(recoveredCount == 2)
        #expect(store.session(id: recording.id)?.status == .recovered(durationSeconds: 90))
        #expect(store.session(id: finalizing.id)?.status == .recovered(durationSeconds: 120))
        #expect(store.session(id: saved.id)?.status == .saved(durationSeconds: 60))
    }
}
