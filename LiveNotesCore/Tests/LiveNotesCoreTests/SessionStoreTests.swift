import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Session store")
struct SessionStoreTests {
    @Test("new recording creates a preparing session at the top of the sidebar")
    func newRecordingCreatesPreparingSession() {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 1_800))

        let session = store.createRecording(named: "Untitled Recording")

        #expect(store.sessions.first?.id == session.id)
        #expect(store.sessions.first?.title == "Untitled Recording")
        #expect(store.sessions.first?.status == .preparing)
        #expect(store.selectedSessionID == session.id)
    }

    @Test("session status follows the recording lifecycle")
    func recordingLifecycle() throws {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 2_400))
        let session = store.createRecording(named: "Neural Networks")

        try store.startRecording(session.id)
        #expect(store.session(id: session.id)?.status == .recording(elapsedSeconds: 0))

        try store.pauseRecording(session.id, elapsedSeconds: 908)
        #expect(store.session(id: session.id)?.status == .paused(elapsedSeconds: 908))

        try store.finalizeRecording(session.id, progress: 0.62)
        #expect(store.session(id: session.id)?.status == .finalizing(progress: 0.62))

        try store.saveRecording(session.id, durationSeconds: 3_120)
        #expect(store.session(id: session.id)?.status == .saved(durationSeconds: 3_120))
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

    @Test("recovered audio appears as a sidebar session")
    func recoveredAudioAppearsInSidebar() {
        var store = SessionStore.clocked(date: Date(timeIntervalSince1970: 4_200))

        let recovered = store.recoverAudio(
            title: "Recovered Audio",
            durationSeconds: 2_280,
            lastSavedAt: Date(timeIntervalSince1970: 4_000)
        )

        #expect(store.sessions.first?.id == recovered.id)
        #expect(store.sessions.first?.status == .recovered(durationSeconds: 2_280))
        #expect(store.selectedSessionID == recovered.id)
    }
}
