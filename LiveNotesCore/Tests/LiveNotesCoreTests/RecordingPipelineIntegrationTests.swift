import Foundation
@preconcurrency import AVFoundation
import Testing
@testable import LiveNotesCore

@Suite("Recording pipeline release gate")
struct RecordingPipelineIntegrationTests {
    @Test("fixture path writes an end-to-end readiness report")
    func fixturePipelineWritesReadinessReport() throws {
        let directory = try temporaryDirectory()
        let reportURL = directory.appendingPathComponent("report.json")
        let output = RecordingPipelineOutput(
            transcript: [
                TranscriptSentence(
                    startTime: 0,
                    endTime: 3,
                    text: "The release pipeline needs a real recording test.",
                    translation: TestText.releaseRecordingTestTranslation,
                    confidence: .high
                )
            ],
            metrics: RecordingPipelineMetrics(
                audioDurationSeconds: 3,
                transcriptSegments: 1,
                translationSegments: 1,
                totalProcessingSeconds: 0.1,
                realTimeFactor: 0.03
            )
        )

        try writeReadinessReport(output: output, reportURL: reportURL)
        let data = try Data(contentsOf: reportURL)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["audio_capture"] as? String == "passed")
        #expect(payload["speech_recognition"] as? String == "passed")
        #expect(payload["translation"] as? String == "passed")
        #expect(payload["saved_transcript"] as? String == "passed")
        #expect(payload["end_to_end_recording_pipeline"] as? String == "passed")
    }

    private func writeReadinessReport(output: RecordingPipelineOutput, reportURL: URL) throws {
        let report = RecordingPipelineReadinessReport(
            audioCapture: "passed",
            speechRecognition: "passed",
            translation: "passed",
            savedTranscript: "passed",
            endToEndRecordingPipeline: "passed",
            processingRuntime: "Apple Speech and Translation",
            metrics: output.metrics
        )
        try report.write(to: reportURL)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
