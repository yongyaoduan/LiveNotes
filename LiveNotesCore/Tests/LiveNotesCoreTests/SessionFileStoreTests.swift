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

    @Test("snapshot export preserves recorded audio and current translations")
    func snapshotExportPreservesRecordedAudioAndCurrentTranslations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let audioURL = fileStore.localFileURL(relativePath: "recording.caf")
        let audio = Data([0, 1, 2, 3, 128, 255])
        try audio.write(to: audioURL)
        let session = RecordingSession(
            title: "Current Notes",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12),
            audioFileName: "recording.caf",
            transcript: [
                TranscriptSentence(
                    startTime: 0,
                    endTime: 4,
                    text: "This translation was already reviewed.",
                    translation: "这段翻译已经校对。",
                    confidence: .high
                ),
                TranscriptSentence(
                    startTime: 5,
                    endTime: 8,
                    text: "This line has no translation yet.",
                    translation: "",
                    confidence: .high
                )
            ]
        )
        try fileStore.save([session])
        let libraryBeforeExport = try Data(contentsOf: fileStore.url)
        let markdownURL = directory.appendingPathComponent("Exports/Current Notes.md")

        try fileStore.exportSnapshot(session, to: markdownURL)

        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(markdown.contains("This translation was already reviewed."))
        #expect(markdown.contains("这段翻译已经校对。"))
        #expect(markdown.contains("This line has no translation yet."))
        #expect(markdown.contains("Translation unavailable."))
        #expect(try Data(contentsOf: markdownURL.deletingPathExtension().appendingPathExtension("caf")) == audio)
        #expect(try Data(contentsOf: audioURL) == audio)
        #expect(try Data(contentsOf: fileStore.url) == libraryBeforeExport)
    }

    @Test("snapshot export can replace an earlier export")
    func snapshotExportCanReplaceEarlierExport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let audioURL = fileStore.localFileURL(relativePath: "recording.m4a")
        try Data([1, 2, 3]).write(to: audioURL)
        var session = RecordingSession(
            title: "Original Notes",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12),
            audioFileName: "recording.m4a"
        )
        let markdownURL = directory.appendingPathComponent("Exports/Notes.md")
        try fileStore.exportSnapshot(session, to: markdownURL)
        session.title = "Updated Notes"
        let newAudio = Data([4, 5, 6])
        try newAudio.write(to: audioURL)

        try fileStore.exportSnapshot(session, to: markdownURL)

        #expect(try String(contentsOf: markdownURL, encoding: .utf8).contains("# Updated Notes"))
        #expect(try Data(contentsOf: markdownURL.deletingPathExtension().appendingPathExtension("m4a")) == newAudio)
        let exportedFiles = try FileManager.default.contentsOfDirectory(atPath: markdownURL.deletingLastPathComponent().path)
        #expect(Set(exportedFiles) == ["Notes.md", "Notes.m4a"])
    }

    @Test("snapshot export with missing source audio preserves existing exports")
    func snapshotExportWithMissingSourceAudioPreservesExistingExports() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let markdownURL = directory.appendingPathComponent("Notes.md")
        let existingAudioURL = directory.appendingPathComponent("Notes.m4a")
        let existingAudio = Data([4, 5, 6])
        try "Existing notes".write(to: markdownURL, atomically: true, encoding: .utf8)
        try existingAudio.write(to: existingAudioURL)
        let session = RecordingSession(
            title: "Missing Audio",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12),
            audioFileName: "missing.m4a"
        )

        #expect(throws: CocoaError.self) {
            try fileStore.exportSnapshot(session, to: markdownURL)
        }

        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == "Existing notes")
        #expect(try Data(contentsOf: existingAudioURL) == existingAudio)
    }

    @Test("snapshot export beside source audio preserves the recording")
    func snapshotExportBesideSourceAudioPreservesRecording() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let audioURL = fileStore.localFileURL(relativePath: "Notes.m4a")
        let audio = Data([1, 2, 3])
        try audio.write(to: audioURL)
        let session = RecordingSession(
            title: "Notes",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12),
            audioFileName: "Notes.m4a"
        )
        let markdownURL = directory.appendingPathComponent("Notes.md")

        try fileStore.exportSnapshot(session, to: markdownURL)

        #expect(try Data(contentsOf: audioURL) == audio)
        #expect(try String(contentsOf: markdownURL, encoding: .utf8).contains("# Notes"))
    }

    @Test("snapshot export preserves existing audio when the Markdown destination is a directory")
    func snapshotExportPreservesAudioWhenMarkdownDestinationIsDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let audioURL = fileStore.localFileURL(relativePath: "recording.m4a")
        let sourceAudio = Data([1, 2, 3])
        try sourceAudio.write(to: audioURL)
        let markdownURL = directory.appendingPathComponent("Notes.md")
        try FileManager.default.createDirectory(at: markdownURL, withIntermediateDirectories: true)
        let retainedFileURL = markdownURL.appendingPathComponent("keep.txt")
        try "Keep this file".write(to: retainedFileURL, atomically: true, encoding: .utf8)
        let exportedAudioURL = directory.appendingPathComponent("Notes.m4a")
        let existingAudio = Data([4, 5, 6])
        try existingAudio.write(to: exportedAudioURL)
        let session = RecordingSession(
            title: "Notes",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12),
            audioFileName: "recording.m4a"
        )

        #expect(throws: CocoaError.self) {
            try fileStore.exportSnapshot(session, to: markdownURL)
        }

        #expect(try String(contentsOf: retainedFileURL, encoding: .utf8) == "Keep this file")
        #expect(try Data(contentsOf: exportedAudioURL) == existingAudio)
        #expect(try Data(contentsOf: audioURL) == sourceAudio)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["Notes.md", "Notes.m4a", "recording.m4a"])
    }

    @Test("failed audio replacement restores the previous export", arguments: [true, false])
    func failedAudioReplacementRestoresPreviousExport(existingMarkdown: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let audioURL = fileStore.localFileURL(relativePath: "recording.m4a")
        let sourceAudio = Data([1, 2, 3])
        try sourceAudio.write(to: audioURL)
        let exportDirectory = directory.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let markdownURL = exportDirectory.appendingPathComponent("Notes.md")
        if existingMarkdown {
            try "Previous notes".write(to: markdownURL, atomically: true, encoding: .utf8)
        }
        let exportedAudioURL = exportDirectory.appendingPathComponent("Notes.m4a")
        let existingAudio = Data([4, 5, 6])
        try existingAudio.write(to: exportedAudioURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: exportedAudioURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: exportedAudioURL.path) }
        let session = RecordingSession(
            title: "New notes",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12),
            audioFileName: "recording.m4a"
        )

        #expect(throws: CocoaError.self) {
            try fileStore.exportSnapshot(session, to: markdownURL)
        }

        if existingMarkdown {
            #expect(try String(contentsOf: markdownURL, encoding: .utf8) == "Previous notes")
        } else {
            #expect(!FileManager.default.fileExists(atPath: markdownURL.path))
        }
        #expect(try Data(contentsOf: exportedAudioURL) == existingAudio)
        #expect(try Data(contentsOf: audioURL) == sourceAudio)
        let exportedFiles = Set(try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path))
        #expect(exportedFiles == (existingMarkdown ? ["Notes.md", "Notes.m4a"] : ["Notes.m4a"]))
    }

    @Test("snapshot export supports notes without an audio attachment")
    func snapshotExportSupportsNotesWithoutAudioAttachment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = SessionFileStore(url: directory.appendingPathComponent("sessions.json"))
        let session = RecordingSession(
            title: "Notes",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12)
        )
        let markdownURL = directory.appendingPathComponent("Exports/Notes.md")

        try fileStore.exportSnapshot(session, to: markdownURL)

        #expect(try String(contentsOf: markdownURL, encoding: .utf8).contains("# Notes"))
        let exportedFiles = try FileManager.default.contentsOfDirectory(atPath: markdownURL.deletingLastPathComponent().path)
        #expect(exportedFiles == ["Notes.md"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
