import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Markdown exporter")
struct MarkdownExporterTests {
    @Test("export includes topic notes, transcript, translations, and timestamps")
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

        let markdown = MarkdownExporter().export(session)

        #expect(markdown.contains("# Neural Networks"))
        #expect(markdown.contains("## Activation Functions"))
        #expect(markdown.contains("14:43 - 21:29"))
        #expect(markdown.contains("Activation functions add non-linearity"))
        #expect(markdown.contains("### Transcript"))
        #expect(markdown.contains("[14:43] Activation functions turn linear outputs"))
        #expect(markdown.contains(TestText.activationFunctionTranslation))
    }
}
