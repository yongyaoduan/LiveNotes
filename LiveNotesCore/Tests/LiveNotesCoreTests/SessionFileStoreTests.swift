import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Session file store")
struct SessionFileStoreTests {
    @Test("session file store saves and restores sessions")
    func savesAndRestoresSessions() throws {
        let directory = try temporaryDirectory()
        let storeURL = directory.appendingPathComponent("sessions.json")
        let fileStore = SessionFileStore(url: storeURL)
        let original = RecordingSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: "Neural Networks",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 3_120),
            transcript: [
                TranscriptSentence(
                    startTime: 883,
                    endTime: 895,
                    text: "Activation functions turn linear outputs into useful signals.",
                    translation: TestText.activationFunctionTranslation,
                    confidence: .high
                )
            ],
            topics: [
                TopicNote(
                    title: "Activation Functions",
                    startTime: 883,
                    endTime: 1_289,
                    summary: "Activation functions add non-linearity to model outputs.",
                    keyPoints: ["They transform linear outputs."],
                    questions: ["Why does non-linearity matter?"]
                )
            ]
        )

        try fileStore.save([original])
        let restored = try fileStore.load()

        #expect(restored == [original])
    }

    @Test("missing session file loads an empty library")
    func missingSessionFileLoadsEmptyLibrary() throws {
        let directory = try temporaryDirectory()
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))

        let sessions = try fileStore.load()

        #expect(sessions.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
