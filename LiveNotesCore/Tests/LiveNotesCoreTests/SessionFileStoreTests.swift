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
            audioFileName: "Audio/neural-networks.m4a",
            transcript: [
                TranscriptSentence(
                    startTime: 883,
                    endTime: 895,
                    text: "Activation functions turn linear outputs into useful signals.",
                    translation: TestText.activationFunctionTranslation,
                    confidence: .high
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

    @Test("local file URLs stay inside the library directory")
    func localFileURLsStayInsideLibraryDirectory() throws {
        let directory = try temporaryDirectory()
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))

        let audioURL = fileStore.localFileURL(relativePath: "Audio/session.m4a")

        #expect(audioURL == directory.appendingPathComponent("Audio/session.m4a"))
    }

    @Test("corrupt session file is preserved and loads an empty library")
    func corruptSessionFileIsPreserved() throws {
        let directory = try temporaryDirectory()
        let storeURL = directory.appendingPathComponent("sessions.json")
        try Data("not json".utf8).write(to: storeURL)
        let fileStore = SessionFileStore(url: storeURL)

        let result = fileStore.loadPreservingCorruptFile()

        #expect(result.sessions.isEmpty)
        let recovery = try #require(result.recovery)
        #expect(recovery.message == "Library file could not be read and was preserved.")
        #expect(FileManager.default.fileExists(atPath: recovery.backupURL.path))
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
