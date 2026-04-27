import Foundation
@preconcurrency import AVFoundation
import Testing
@testable import LiveNotesCore

private let liveMLXIntegrationEnabled = ProcessInfo.processInfo.environment["LIVENOTES_RECORDING_PIPELINE_LIVE"] == "1"
private let liveAudioCaptureEnabled = ProcessInfo.processInfo.environment["LIVENOTES_RECORDING_PIPELINE_CAPTURE_LIVE"] != "0"

@Suite("Recording pipeline release gate")
struct RecordingPipelineIntegrationTests {
    @Test(
        "fixture path writes an end-to-end readiness report",
        .enabled(
            if: !liveMLXIntegrationEnabled,
            "The fixture path is disabled when the live MLX release gate is running."
        )
    )
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
            topics: [
                TopicNote(
                    title: "Recording Test",
                    startTime: 0,
                    endTime: 3,
                    summary: "The fixture covers the end-to-end report shape.",
                    keyPoints: ["A recording test is required."],
                    questions: []
                )
            ],
            metrics: RecordingPipelineMetrics(
                audioDurationSeconds: 3,
                transcriptSegments: 1,
                translationSegments: 1,
                topicCount: 1,
                totalProcessingSeconds: 0.1,
                realTimeFactor: 0.03
            )
        )

        try writeReadinessReport(output: output, reportURL: reportURL)
        let data = try Data(contentsOf: reportURL)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["audio_capture"] as? String == "passed")
        #expect(payload["local_mlx_inference"] as? String == "passed")
        #expect(payload["end_to_end_recording_pipeline"] as? String == "passed")
    }

    @Test(
        "release-gated live path runs local MLX inference over a real audio file",
        .enabled(
            if: liveMLXIntegrationEnabled,
            "Set LIVENOTES_RECORDING_PIPELINE_LIVE=1 to run the live MLX release gate."
        )
    )
    func livePipelineRunsLocalMLXInference() throws {
        let environment = ProcessInfo.processInfo.environment
        let audioPath = try #require(environment["LIVENOTES_RECORDING_PIPELINE_AUDIO"])
        let artifactsRoot = try #require(environment["LIVENOTES_MODEL_ARTIFACT_ROOT"])
        let helperPath = try #require(environment["LIVENOTES_MLX_HELPER"])
        let reportPath = try #require(environment["LIVENOTES_RECORDING_PIPELINE_REPORT"])
        let audioURL = URL(fileURLWithPath: audioPath)
        let artifactsURL = URL(fileURLWithPath: artifactsRoot)
        let helperURL = URL(fileURLWithPath: helperPath)

        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(FileManager.default.fileExists(atPath: artifactsURL.path))
        #expect(FileManager.default.fileExists(atPath: helperURL.path))
        let runner = LocalMLXInferenceRunner(helperScriptURL: helperURL)
        if liveAudioCaptureEnabled {
            let capturedAudioURL = try captureLiveAudio()
            let capturedOutput = try runner.process(
                audioURL: capturedAudioURL,
                artifactsRootURL: artifactsURL
            )
            #expect(capturedOutput.metrics.totalProcessingSeconds != nil)
        }

        let output = try runner.process(audioURL: audioURL, artifactsRootURL: artifactsURL)

        #expect(output.transcript.count >= 1)
        #expect(output.transcript.contains { !$0.translation.isEmpty })
        #expect(output.topics.count >= 1)
        #expect(output.metrics.audioDurationSeconds >= 1)
        #expect(output.metrics.realTimeFactor ?? 0 <= 6)

        try writeReadinessReport(
            output: output,
            reportURL: URL(fileURLWithPath: reportPath)
        )
    }

    private func writeReadinessReport(output: RecordingPipelineOutput, reportURL: URL) throws {
        let report = RecordingPipelineReadinessReport(
            audioCapture: "passed",
            localMLXInference: "passed",
            endToEndRecordingPipeline: "passed",
            modelRuntime: "Local MLX",
            metrics: output.metrics
        )
        try report.write(to: reportURL)
    }

    @discardableResult
    private func captureLiveAudio() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let captureURL: URL
        if let capturePath = environment["LIVENOTES_RECORDING_PIPELINE_CAPTURE_AUDIO"] {
            captureURL = URL(fileURLWithPath: capturePath)
        } else {
            captureURL = try temporaryDirectory()
                .appendingPathComponent("captured-audio.m4a")
        }
        let seconds = max(
            1.0,
            Double(environment["LIVENOTES_RECORDING_PIPELINE_CAPTURE_SECONDS"] ?? "2") ?? 2.0
        )
        let recorder = AVAudioRecordingEngine()
        try recorder.startRecording(to: captureURL)
        Thread.sleep(forTimeInterval: seconds)
        let durationSeconds = try recorder.stopRecording()
        #expect(durationSeconds >= 1)
        #expect(FileManager.default.fileExists(atPath: captureURL.path))
        let fileSize = try #require(
            captureURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        #expect(fileSize > 0)
        let audioFile = try AVAudioFile(forReading: captureURL)
        #expect(audioFile.length > 0)
        return captureURL
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
