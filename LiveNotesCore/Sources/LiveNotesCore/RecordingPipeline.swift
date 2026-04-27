import Foundation
@preconcurrency import AVFoundation

public enum RecordingPipelineError: Error, LocalizedError, Sendable {
    case audioFileUnavailable
    case runtimeFailed(String)
    case invalidRuntimeOutput(String)

    public var errorDescription: String? {
        switch self {
        case .audioFileUnavailable:
            return "Audio file is not available."
        case let .runtimeFailed(message):
            return message
        case let .invalidRuntimeOutput(message):
            return message
        }
    }
}

public struct RecordingPipelineOutput: Equatable, Sendable {
    public var transcript: [TranscriptSentence]
    public var topics: [TopicNote]
    public var metrics: RecordingPipelineMetrics

    public init(
        transcript: [TranscriptSentence],
        topics: [TopicNote],
        metrics: RecordingPipelineMetrics
    ) {
        self.transcript = transcript
        self.topics = topics
        self.metrics = metrics
    }
}

public struct RecordingPipelineMetrics: Codable, Equatable, Sendable {
    public var audioDurationSeconds: Double
    public var transcriptSegments: Int
    public var translationSegments: Int
    public var topicCount: Int
    public var modelLoadSeconds: Double?
    public var transcriptionProcessingSeconds: Double?
    public var translationProcessingSeconds: Double?
    public var topicProcessingSeconds: Double?
    public var totalProcessingSeconds: Double?
    public var realTimeFactor: Double?

    public init(
        audioDurationSeconds: Double,
        transcriptSegments: Int,
        translationSegments: Int,
        topicCount: Int,
        modelLoadSeconds: Double? = nil,
        transcriptionProcessingSeconds: Double? = nil,
        translationProcessingSeconds: Double? = nil,
        topicProcessingSeconds: Double? = nil,
        totalProcessingSeconds: Double? = nil,
        realTimeFactor: Double? = nil
    ) {
        self.audioDurationSeconds = audioDurationSeconds
        self.transcriptSegments = transcriptSegments
        self.translationSegments = translationSegments
        self.topicCount = topicCount
        self.modelLoadSeconds = modelLoadSeconds
        self.transcriptionProcessingSeconds = transcriptionProcessingSeconds
        self.translationProcessingSeconds = translationProcessingSeconds
        self.topicProcessingSeconds = topicProcessingSeconds
        self.totalProcessingSeconds = totalProcessingSeconds
        self.realTimeFactor = realTimeFactor
    }
}

public protocol AudioRecordingControlling: AnyObject {
    func startRecording(to url: URL) throws
    func pauseRecording()
    func resumeRecording() throws
    func stopRecording() throws -> Int
}

public final class AVAudioRecordingEngine: AudioRecordingControlling {
    private let engine = AVAudioEngine()
    private let stateQueue = DispatchQueue(label: "app.livenotes.recording-engine.state")
    private var audioFile: AVAudioFile?
    private var startedAt: Date?
    private var accumulatedSeconds: TimeInterval = 0
    private var writeError: Error?

    public init() {}

    public func startRecording(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        stateQueue.sync {
            audioFile = file
            startedAt = nil
            accumulatedSeconds = 0
            writeError = nil
        }
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            stateQueue.sync {
                startedAt = Date()
            }
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            stateQueue.sync {
                audioFile = nil
                startedAt = nil
            }
            throw error
        }
    }

    public func pauseRecording() {
        guard engine.isRunning else { return }
        let now = Date()
        stateQueue.sync {
            accumulatedSeconds += now.timeIntervalSince(startedAt ?? now)
            startedAt = nil
        }
        engine.pause()
    }

    public func resumeRecording() throws {
        guard !engine.isRunning else { return }
        try engine.start()
        stateQueue.sync {
            startedAt = Date()
        }
    }

    public func stopRecording() throws -> Int {
        if engine.isRunning {
            let now = Date()
            stateQueue.sync {
                accumulatedSeconds += now.timeIntervalSince(startedAt ?? now)
                startedAt = nil
            }
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        return try stateQueue.sync {
            audioFile = nil
            startedAt = nil
            if let writeError {
                self.writeError = nil
                throw writeError
            }
            return max(0, Int(accumulatedSeconds.rounded()))
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        stateQueue.sync {
            guard let audioFile else { return }
            do {
                try audioFile.write(from: buffer)
            } catch {
                writeError = error
            }
        }
    }
}

public protocol RecordingInferenceRunning: Sendable {
    func process(audioURL: URL, artifactsRootURL: URL) throws -> RecordingPipelineOutput
}

public struct LocalMLXInferenceRunner: RecordingInferenceRunning {
    public var pythonExecutable: String
    public var helperScriptURL: URL
    public var timeoutSeconds: TimeInterval

    public init(
        pythonExecutable: String = ProcessInfo.processInfo.environment["LIVENOTES_PYTHON"] ?? "python3",
        helperScriptURL: URL,
        timeoutSeconds: TimeInterval = 1_800
    ) {
        self.pythonExecutable = pythonExecutable
        self.helperScriptURL = helperScriptURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func process(audioURL: URL, artifactsRootURL: URL) throws -> RecordingPipelineOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            pythonExecutable,
            helperScriptURL.path,
            "--audio", audioURL.path,
            "--artifacts-root", artifactsRootURL.path
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let outputCapture = PipeCapture()
        let errorCapture = PipeCapture()
        let pipeGroup = DispatchGroup()
        pipeGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputCapture.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            pipeGroup.leave()
        }
        pipeGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorCapture.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            pipeGroup.leave()
        }

        let deadline = DispatchTime.now() + timeoutSeconds
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            group.wait()
            pipeGroup.wait()
            throw RecordingPipelineError.runtimeFailed("Local MLX inference timed out.")
        }
        pipeGroup.wait()

        let output = String(
            data: outputCapture.data,
            encoding: .utf8
        ) ?? ""
        _ = errorCapture.data
        guard process.terminationStatus == 0 else {
            throw RecordingPipelineError.runtimeFailed("Local MLX inference failed.")
        }
        return try Self.decodeOutput(output)
    }

    public static func decodeOutput(_ output: String) throws -> RecordingPipelineOutput {
        guard let data = output.data(using: .utf8) else {
            throw RecordingPipelineError.invalidRuntimeOutput("Local MLX inference returned unreadable output.")
        }
        do {
            let payload = try JSONDecoder().decode(RuntimeOutput.self, from: data)
            return RecordingPipelineOutput(
                transcript: payload.transcript.map {
                    TranscriptSentence(
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        text: $0.text,
                        translation: $0.translation,
                        confidence: $0.confidence
                    )
                },
                topics: payload.topics.map {
                    TopicNote(
                        title: $0.title,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        summary: $0.summary,
                        keyPoints: $0.keyPoints,
                        questions: $0.questions
                    )
                },
                metrics: payload.metrics
            )
        } catch {
            throw RecordingPipelineError.invalidRuntimeOutput("Local MLX inference returned invalid JSON.")
        }
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedData = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return capturedData
    }

    func set(_ data: Data) {
        lock.lock()
        capturedData = data
        lock.unlock()
    }
}

private struct RuntimeOutput: Decodable {
    var transcript: [RuntimeTranscriptSentence]
    var topics: [RuntimeTopicNote]
    var metrics: RecordingPipelineMetrics
}

private struct RuntimeTranscriptSentence: Decodable {
    var startTime: Int
    var endTime: Int
    var text: String
    var translation: String
    var confidence: TranscriptConfidence
}

private struct RuntimeTopicNote: Decodable {
    var title: String
    var startTime: Int
    var endTime: Int?
    var summary: String
    var keyPoints: [String]
    var questions: [String]
}

public struct RecordingPipelineReadinessReport: Codable, Equatable, Sendable {
    public var audioCapture: String
    public var localMLXInference: String
    public var endToEndRecordingPipeline: String
    public var modelRuntime: String
    public var metrics: RecordingPipelineMetrics

    public init(
        audioCapture: String,
        localMLXInference: String,
        endToEndRecordingPipeline: String,
        modelRuntime: String,
        metrics: RecordingPipelineMetrics
    ) {
        self.audioCapture = audioCapture
        self.localMLXInference = localMLXInference
        self.endToEndRecordingPipeline = endToEndRecordingPipeline
        self.modelRuntime = modelRuntime
        self.metrics = metrics
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}
