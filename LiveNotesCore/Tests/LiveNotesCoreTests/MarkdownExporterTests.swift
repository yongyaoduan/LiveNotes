import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Markdown exporter")
struct MarkdownExporterTests {
    @Test("export includes transcript, translations, and timestamps")
    func exportIncludesSavedCoreContent() {
        let session = RecordingSession(
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
            ]
        )

        let markdown = MarkdownExporter().export(session)

        #expect(markdown.contains("# Neural Networks"))
        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("[14:43] Activation functions turn linear outputs"))
        #expect(markdown.contains(TestText.activationFunctionTranslation))
        #expect(!markdown.contains("## Topics"))
        #expect(!markdown.contains("### Key Points"))
    }

    @Test("export marks missing translations")
    func exportMarksMissingTranslations() {
        let session = RecordingSession(
            title: "Audio Check",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 60),
            transcript: [
                TranscriptSentence(
                    startTime: 0,
                    endTime: 4,
                    text: "The translation service was not ready.",
                    translation: "",
                    confidence: .high
                )
            ]
        )

        let markdown = MarkdownExporter().export(session)

        #expect(session.hasMissingTranslations)
        #expect(markdown.contains("Translation unavailable."))
    }

    @Test("export coalesces saved phrase-level transcript fragments")
    func exportCoalescesSavedPhraseLevelTranscriptFragments() {
        let session = RecordingSession(
            title: "Fragmented Recording",
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .saved(durationSeconds: 12),
            transcript: [
                TranscriptSentence(
                    startTime: 0,
                    endTime: 1,
                    text: "And I",
                    translation: "还有我",
                    confidence: .high
                ),
                TranscriptSentence(
                    startTime: 1,
                    endTime: 2,
                    text: "will talk to you about",
                    translation: "会和你谈谈",
                    confidence: .high
                ),
                TranscriptSentence(
                    startTime: 2,
                    endTime: 3,
                    text: "the assignment.",
                    translation: "作业。",
                    confidence: .high
                )
            ]
        )

        let markdown = MarkdownExporter().export(session)

        #expect(markdown.contains("[00:00] And I will talk to you about the assignment."))
        #expect(markdown.contains("还有我 会和你谈谈 作业。"))
        #expect(!markdown.contains("[00:01] will talk to you about"))
        #expect(!markdown.contains("[00:02] the assignment."))
    }

    @Test("export directory history starts from the last saved directory")
    func exportDirectoryHistoryStartsFromLastSavedDirectory() throws {
        let suiteName = "LiveNotesExportDirectoryHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let history = ExportDirectoryHistory(defaults: defaults)
        let defaultDirectory = URL(fileURLWithPath: "/tmp/livenotes-default", isDirectory: true)
        let savedURL = URL(fileURLWithPath: "/Users/example/Downloads/test002.md")

        #expect(history.directory(defaultDirectory: defaultDirectory) == defaultDirectory)

        history.rememberExportURL(savedURL)

        #expect(history.directory(defaultDirectory: defaultDirectory).path == "/Users/example/Downloads")
    }
}
