import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Recording pipeline")
struct RecordingPipelineTests {
    @Test("local MLX runner decodes transcript, translation, topics, and metrics")
    func decodesLocalMLXOutput() throws {
        let output = """
        {
          "transcript": [
            {
              "startTime": 0,
              "endTime": 4,
              "text": "We should follow up with the customer.",
              "translation": "\(TestText.customerFollowUpTranslation)",
              "confidence": "high"
            }
          ],
          "topics": [
            {
              "title": "Customer Follow-up",
              "startTime": 0,
              "endTime": 4,
              "summary": "The session identifies a customer follow-up.",
              "keyPoints": ["Customer follow-up is required."],
              "questions": []
            }
          ],
          "metrics": {
            "audioDurationSeconds": 4,
            "transcriptSegments": 1,
            "translationSegments": 1,
            "topicCount": 1,
            "totalProcessingSeconds": 2.5,
            "realTimeFactor": 0.625
          }
        }
        """

        let result = try LocalMLXInferenceRunner.decodeOutput(output)

        #expect(result.transcript.count == 1)
        #expect(result.transcript[0].text == "We should follow up with the customer.")
        #expect(result.transcript[0].translation == TestText.customerFollowUpTranslation)
        #expect(result.topics.count == 1)
        #expect(result.topics[0].title == "Customer Follow-up")
        #expect(result.metrics.transcriptSegments == 1)
        #expect(result.metrics.translationSegments == 1)
        #expect(result.metrics.topicCount == 1)
        #expect(result.metrics.totalProcessingSeconds == 2.5)
        #expect(result.metrics.realTimeFactor == 0.625)
    }

    @Test("readiness report writes release gate keys")
    func readinessReportWritesSnakeCaseKeys() throws {
        let directory = try temporaryDirectory()
        let reportURL = directory.appendingPathComponent("report.json")
        let report = RecordingPipelineReadinessReport(
            audioCapture: "passed",
            localMLXInference: "passed",
            endToEndRecordingPipeline: "passed",
            modelRuntime: "Local MLX",
            metrics: RecordingPipelineMetrics(
                audioDurationSeconds: 2,
                transcriptSegments: 1,
                translationSegments: 1,
                topicCount: 1
            )
        )

        try report.write(to: reportURL)
        let data = try Data(contentsOf: reportURL)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try #require(payload["metrics"] as? [String: Any])

        #expect(payload["audio_capture"] as? String == "passed")
        #expect(payload["local_mlx_inference"] as? String == "passed")
        #expect(payload["end_to_end_recording_pipeline"] as? String == "passed")
        #expect(payload["model_runtime"] as? String == "Local MLX")
        #expect(metrics["audio_duration_seconds"] as? Double == 2)
        #expect(metrics["transcript_segments"] as? Int == 1)
    }

    @Test("runner parses stdout JSON while runtime logs go to stderr")
    func runnerSeparatesRuntimeLogsFromJSON() throws {
        let directory = try temporaryDirectory()
        let helperURL = directory.appendingPathComponent("helper.sh")
        let audioURL = directory.appendingPathComponent("audio.wav")
        let artifactsURL = directory.appendingPathComponent("artifacts", isDirectory: true)
        try Data().write(to: audioURL)
        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf 'loading local MLX model\\n' >&2
        cat <<'JSON'
        {
          "transcript": [
            {
              "startTime": 0,
              "endTime": 2,
              "text": "Real runtime output.",
              "translation": "\(TestText.runtimeOutputTranslation)",
              "confidence": "high"
            }
          ],
          "topics": [
            {
              "title": "Runtime",
              "startTime": 0,
              "endTime": 2,
              "summary": "The runtime emitted JSON on stdout.",
              "keyPoints": ["JSON stays separate from logs."],
              "questions": []
            }
          ],
          "metrics": {
            "audioDurationSeconds": 2,
            "transcriptSegments": 1,
            "translationSegments": 1,
            "topicCount": 1
          }
        }
        JSON
        """.write(to: helperURL, atomically: true, encoding: .utf8)

        let runner = LocalMLXInferenceRunner(
            pythonExecutable: "/bin/bash",
            helperScriptURL: helperURL,
            timeoutSeconds: 5
        )
        let output = try runner.process(audioURL: audioURL, artifactsRootURL: artifactsURL)

        #expect(output.transcript.first?.text == "Real runtime output.")
        #expect(output.transcript.first?.translation == TestText.runtimeOutputTranslation)
        #expect(output.topics.first?.title == "Runtime")
    }

    @Test("runner drains large stdout and stderr before decoding JSON")
    func runnerDrainsLargeOutputPipes() throws {
        let directory = try temporaryDirectory()
        let helperURL = directory.appendingPathComponent("large-output-helper.sh")
        let audioURL = directory.appendingPathComponent("audio.wav")
        let artifactsURL = directory.appendingPathComponent("artifacts", isDirectory: true)
        try Data().write(to: audioURL)
        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        try """
        #!/usr/bin/env bash
        set -euo pipefail

        write_large_text() {
          local count="$1"
          for ((index = 0; index < count; index++)); do
            printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
          done
        }

        write_large_text 4096 >&2
        printf '\\n' >&2
        printf '{"transcript":[{"startTime":0,"endTime":2,"text":"Large pipe output.","translation":"Large pipe translation.","confidence":"high"}],"topics":[{"title":"Pipe Drain","startTime":0,"endTime":2,"summary":"The runner drained both pipes while the helper was running.","keyPoints":["Both pipes were drained."],"questions":[]}],"metrics":{"audioDurationSeconds":2,"transcriptSegments":1,"translationSegments":1,"topicCount":1},"padding":"'
        write_large_text 4096
        printf '"}\\n'
        """.write(to: helperURL, atomically: true, encoding: .utf8)

        let runner = LocalMLXInferenceRunner(
            pythonExecutable: "/bin/bash",
            helperScriptURL: helperURL,
            timeoutSeconds: 2
        )
        let output = try runner.process(audioURL: audioURL, artifactsRootURL: artifactsURL)

        #expect(output.transcript.first?.text == "Large pipe output.")
        #expect(output.topics.first?.title == "Pipe Drain")
        #expect(output.metrics.transcriptSegments == 1)
    }

    @Test("runner hides helper stderr from user-facing failures")
    func runnerHidesHelperStderrFromUserFacingFailures() throws {
        let directory = try temporaryDirectory()
        let helperURL = directory.appendingPathComponent("failing-helper.sh")
        let audioURL = directory.appendingPathComponent("audio.wav")
        let artifactsURL = directory.appendingPathComponent("artifacts", isDirectory: true)
        try Data().write(to: audioURL)
        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '/private/tmp/internal/path.py failed\\n' >&2
        exit 1
        """.write(to: helperURL, atomically: true, encoding: .utf8)

        let runner = LocalMLXInferenceRunner(
            pythonExecutable: "/bin/bash",
            helperScriptURL: helperURL,
            timeoutSeconds: 2
        )

        do {
            _ = try runner.process(audioURL: audioURL, artifactsRootURL: artifactsURL)
            Issue.record("Expected local MLX inference failure.")
        } catch let error as RecordingPipelineError {
            #expect(error.errorDescription == "Local MLX inference failed.")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
