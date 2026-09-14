import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import OSLog
@preconcurrency import Speech

private let speechPipelineLogger = Logger(subsystem: "app.livenotes.mac", category: "SpeechPipeline")

public enum RecordingPipelineError: Error, LocalizedError, Sendable {
    case audioFileUnavailable
    case microphoneAccessDenied
    case speechRecognitionAccessDenied
    case runtimeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .audioFileUnavailable:
            return "Audio file is not available."
        case .microphoneAccessDenied:
            return "Microphone access is required to record audio."
        case .speechRecognitionAccessDenied:
            return "LiveNotes needs permission to transcribe audio."
        case let .runtimeFailed(message):
            return message
        }
    }
}

public struct RecordingPipelineOutput: Equatable, Sendable {
    public var transcript: [TranscriptSentence]
    public var metrics: RecordingPipelineMetrics

    public init(
        transcript: [TranscriptSentence],
        metrics: RecordingPipelineMetrics
    ) {
        self.transcript = transcript
        self.metrics = metrics
    }

    public func offset(by seconds: Int) -> RecordingPipelineOutput {
        guard seconds != 0 else {
            return self
        }
        return RecordingPipelineOutput(
            transcript: transcript.map {
                TranscriptSentence(
                    id: $0.id,
                    startTime: $0.startTime + seconds,
                    endTime: $0.endTime + seconds,
                    text: $0.text,
                    translation: $0.translation,
                    confidence: $0.confidence,
                    sourceStartTime: $0.sourceStartTime.map { $0 + Double(seconds) }
                )
            },
            metrics: metrics
        )
    }
}

public struct RecordingPipelineMetrics: Codable, Equatable, Sendable {
    public var audioDurationSeconds: Double
    public var transcriptSegments: Int
    public var translationSegments: Int
    public var transcriptionProcessingSeconds: Double?
    public var translationProcessingSeconds: Double?
    public var totalProcessingSeconds: Double?
    public var realTimeFactor: Double?

    public init(
        audioDurationSeconds: Double,
        transcriptSegments: Int,
        translationSegments: Int,
        transcriptionProcessingSeconds: Double? = nil,
        translationProcessingSeconds: Double? = nil,
        totalProcessingSeconds: Double? = nil,
        realTimeFactor: Double? = nil
    ) {
        self.audioDurationSeconds = audioDurationSeconds
        self.transcriptSegments = transcriptSegments
        self.translationSegments = translationSegments
        self.transcriptionProcessingSeconds = transcriptionProcessingSeconds
        self.translationProcessingSeconds = translationProcessingSeconds
        self.totalProcessingSeconds = totalProcessingSeconds
        self.realTimeFactor = realTimeFactor
    }
}

public protocol AudioRecordingControlling: AnyObject, Sendable {
    func startRecording(to url: URL) async throws
    func pauseRecording()
    func resumeRecording() throws
    func stopRecording() throws -> Int
}

protocol AudioInputProviding: AnyObject, Sendable {
    func outputFormat() throws -> AVAudioFormat
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

enum MicrophonePermissionState: Sendable {
    case granted
    case undetermined
    case denied
}

struct MicrophonePermissionAuthorizer: Sendable {
    let currentState: @Sendable () -> MicrophonePermissionState
    let requestAccess: @Sendable () async -> Bool

    func authorize() async throws {
        switch currentState() {
        case .granted:
            return
        case .undetermined:
            if await requestAccess() {
                return
            }
            throw RecordingPipelineError.microphoneAccessDenied
        case .denied:
            throw RecordingPipelineError.microphoneAccessDenied
        }
    }

    static var live: MicrophonePermissionAuthorizer {
        MicrophonePermissionAuthorizer(
            currentState: liveState,
            requestAccess: requestLiveAccess
        )
    }

    static let preflightGranted = MicrophonePermissionAuthorizer(
        currentState: { .granted },
        requestAccess: { true }
    )

    private static func liveState() -> MicrophonePermissionState {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .granted
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            @unknown default:
                return .denied
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .undetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private static func requestLiveAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

}

enum SpeechRecognitionPermissionState: Sendable {
    case granted
    case undetermined
    case denied
}

struct SpeechRecognitionPermissionAuthorizer: Sendable {
    let currentState: @Sendable () -> SpeechRecognitionPermissionState
    let requestAccess: @Sendable () async -> Bool

    func authorize() async throws {
        switch currentState() {
        case .granted:
            return
        case .undetermined:
            if await requestAccess() {
                return
            }
            throw RecordingPipelineError.speechRecognitionAccessDenied
        case .denied:
            throw RecordingPipelineError.speechRecognitionAccessDenied
        }
    }

    static var live: SpeechRecognitionPermissionAuthorizer {
        SpeechRecognitionPermissionAuthorizer(
            currentState: liveState,
            requestAccess: requestLiveAccess
        )
    }

    static let preflightGranted = SpeechRecognitionPermissionAuthorizer(
        currentState: { .granted },
        requestAccess: { true }
    )

    private static func liveState() -> SpeechRecognitionPermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .granted
        case .notDetermined:
            return .undetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private static func requestLiveAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

public final class AVAudioRecordingEngine: AudioRecordingControlling, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "app.livenotes.recording-engine.state")
    private let bufferProcessingQueue: DispatchQueue
    private let liveAudioHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let microphonePermissionAuthorizer: MicrophonePermissionAuthorizer
    private let audioInputProviderFactory: @Sendable () -> AudioInputProviding
    private var audioInputProvider: AudioInputProviding?
    private var audioFile: AVAudioFile?
    private var startedAt: Date?
    private var accumulatedSeconds: TimeInterval = 0
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var isPaused = false
    private var writeError: Error?
    private var recordingGeneration: UInt64 = 0

    public init(liveAudioHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) {
        self.liveAudioHandler = liveAudioHandler
        bufferProcessingQueue = DispatchQueue(label: "app.livenotes.recording-engine.buffers")
        microphonePermissionAuthorizer = .live
        audioInputProviderFactory = { AVAudioEngineInputProvider() }
    }

    init(
        microphonePermissionAuthorizer: MicrophonePermissionAuthorizer,
        liveAudioHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        audioInputProviderFactory: @escaping @Sendable () -> AudioInputProviding = {
            AVAudioEngineInputProvider()
        },
        bufferProcessingQueue: DispatchQueue = DispatchQueue(label: "app.livenotes.recording-engine.buffers")
    ) {
        self.liveAudioHandler = liveAudioHandler
        self.microphonePermissionAuthorizer = microphonePermissionAuthorizer
        self.audioInputProviderFactory = audioInputProviderFactory
        self.bufferProcessingQueue = bufferProcessingQueue
    }

    public func startRecording(to url: URL) async throws {
        try await microphonePermissionAuthorizer.authorize()
        var activeProvider: AudioInputProviding?
        stateQueue.sync {
            if self.audioInputProvider == nil {
                self.audioInputProvider = audioInputProviderFactory()
            }
            activeProvider = self.audioInputProvider
        }
        guard let provider = activeProvider else {
            throw RecordingPipelineError.runtimeFailed("LiveNotes could not access the microphone.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        provider.stop()
        let format = try provider.outputFormat()
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
            recordedFrameCount = 0
            recordingSampleRate = format.sampleRate
            isPaused = false
            writeError = nil
            recordingGeneration += 1
        }
        do {
            try provider.start { [weak self] buffer in
                self?.write(buffer)
            }
            stateQueue.sync {
                startedAt = Date()
            }
        } catch {
            provider.stop()
            stateQueue.sync {
                audioFile = nil
                audioInputProvider = nil
                startedAt = nil
                accumulatedSeconds = 0
                recordedFrameCount = 0
                recordingSampleRate = 0
                isPaused = false
                recordingGeneration += 1
            }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func pauseRecording() {
        let now = Date()
        stateQueue.sync {
            guard audioFile != nil, !isPaused else { return }
            accumulatedSeconds += now.timeIntervalSince(startedAt ?? now)
            startedAt = nil
            isPaused = true
        }
    }

    public func resumeRecording() throws {
        stateQueue.sync {
            guard audioFile != nil, isPaused else { return }
            isPaused = false
            startedAt = Date()
        }
    }

    public func stopRecording() throws -> Int {
        var activeProvider: AudioInputProviding?
        stateQueue.sync {
            activeProvider = audioInputProvider
        }
        let now = Date()
        stateQueue.sync {
            accumulatedSeconds += now.timeIntervalSince(startedAt ?? now)
            startedAt = nil
        }
        activeProvider?.stop()
        bufferProcessingQueue.sync {}
        let result = try stateQueue.sync {
            let sampleDuration = recordingSampleRate > 0
                ? Double(recordedFrameCount) / recordingSampleRate
                : 0
            audioFile = nil
            audioInputProvider = nil
            startedAt = nil
            isPaused = false
            recordingGeneration += 1
            if let writeError {
                self.writeError = nil
                throw writeError
            }
            return max(0, Int(max(accumulatedSeconds, sampleDuration).rounded()))
        }
        return result
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        var acceptedGeneration: UInt64?
        stateQueue.sync {
            guard audioFile != nil, !isPaused else { return }
            acceptedGeneration = recordingGeneration
        }
        guard let acceptedGeneration else { return }
        guard let copiedBuffer = AudioBufferCopier.copy(buffer) else {
            stateQueue.sync {
                writeError = RecordingPipelineError.runtimeFailed("LiveNotes could not copy microphone audio.")
            }
            return
        }
        bufferProcessingQueue.async { [weak self] in
            self?.writeAcceptedBuffer(copiedBuffer, generation: acceptedGeneration)
        }
    }

    private func writeAcceptedBuffer(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        var liveAudioBuffer: AVAudioPCMBuffer?
        let shouldHandleLiveAudio: Bool = stateQueue.sync {
            guard generation == recordingGeneration, let audioFile else { return false }
            guard let writableBuffer = SpeechAnalyzerAudioConverter.convert(buffer, to: audioFile.processingFormat) else {
                writeError = RecordingPipelineError.runtimeFailed("LiveNotes could not prepare microphone audio.")
                return false
            }
            do {
                try audioFile.write(from: writableBuffer)
                recordedFrameCount += AVAudioFramePosition(writableBuffer.frameLength)
                liveAudioBuffer = writableBuffer
                return true
            } catch {
                writeError = error
            }
            return false
        }
        if shouldHandleLiveAudio, let liveAudioBuffer {
            liveAudioHandler?(liveAudioBuffer)
        }
    }

}

enum AudioTapBufferSize {
    static func frameCount(sampleRate: Double) -> AVAudioFrameCount {
        let safeSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let targetFrames = (safeSampleRate * 0.2).rounded()
        let minimumFrames = (safeSampleRate * 0.1).rounded(.up)
        let maximumFrames = (safeSampleRate * 0.4).rounded(.down)
        let clamped = min(max(targetFrames, minimumFrames), maximumFrames)
        return AVAudioFrameCount(max(1, clamped))
    }
}

private final class AVAudioEngineInputProvider: AudioInputProviding, @unchecked Sendable {
    private let engineFactory: @Sendable () -> AVAudioEngine
    private var engine: AVAudioEngine?

    init(engineFactory: @escaping @Sendable () -> AVAudioEngine = { AVAudioEngine() }) {
        self.engineFactory = engineFactory
    }

    func outputFormat() throws -> AVAudioFormat {
        let engine = activeEngine()
        return engine.inputNode.outputFormat(forBus: 0)
    }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let engine = activeEngine()
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: AudioTapBufferSize.frameCount(sampleRate: format.sampleRate),
            format: format
        ) { buffer, _ in
            bufferHandler(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard let engine else { return }
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private func activeEngine() -> AVAudioEngine {
        if let engine {
            return engine
        }
        let newEngine = engineFactory()
        engine = newEngine
        return newEngine
    }
}

enum AudioFixtureWriter {
    static func writeSineWaveM4A(
        to url: URL,
        durationSeconds: Double,
        sampleRate: Double = 16_000,
        amplitude: Float = 0.35
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingPipelineError.runtimeFailed("Could not create audio fixture.")
        }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channel = buffer.floatChannelData?[0] else {
            throw RecordingPipelineError.runtimeFailed("Could not create audio fixture.")
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channel[frame] = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate)) * amplitude
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}

public enum AudioLevelMeter {
    public static func normalizedLevel(for buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else {
            return 0
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return 0
        }

        var sumSquares = 0.0
        var sampleCount = 0
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = Double(channel[frameIndex])
                sumSquares += sample * sample
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else {
            return 0
        }
        let rms = sqrt(sumSquares / Double(sampleCount))
        guard rms.isFinite, rms > 0 else {
            return 0
        }
        return min(1, rms / 0.25)
    }
}

public protocol RecordingInferenceRunning: Sendable {
    func process(audioURL: URL, artifactsRootURL: URL) throws -> RecordingPipelineOutput
}

public enum LiveTranscriptionEvent: Equatable, Sendable {
    case ready
    case partialTranscript(String)
    case committedTranscript(TranscriptSentence, replacing: [UUID] = [])
    case failed(String)
}

public protocol LiveTranscriptionRunning: AnyObject, Sendable {
    func start(
        eventHandler: @escaping @Sendable (LiveTranscriptionEvent) -> Void
    ) async throws
    func append(_ buffer: AVAudioPCMBuffer)
    func pause()
    func resume()
    func finish() async -> [TranscriptSentence]
    func cancel()
}

struct SpeechAnalyzerTranscriptFragment: Equatable, Sendable {
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval

    static func wholeWords(_ fragments: [Self]) -> [Self] {
        var words: [Self] = []
        var current: Self?
        var leadingWhitespace = ""
        for fragment in fragments {
            for character in fragment.text {
                if character.isWhitespace {
                    if var word = current {
                        word.text.append(character)
                        words.append(word)
                        current = nil
                    } else if !words.isEmpty {
                        words[words.count - 1].text.append(character)
                    } else {
                        leadingWhitespace.append(character)
                    }
                } else if var word = current {
                    word.text.append(character)
                    word.startTime = min(word.startTime, fragment.startTime)
                    word.endTime = max(word.endTime, fragment.endTime)
                    current = word
                } else {
                    current = Self(
                        text: leadingWhitespace + String(character),
                        startTime: fragment.startTime,
                        endTime: fragment.endTime
                    )
                    leadingWhitespace = ""
                }
            }
        }
        if let current { words.append(current) }
        return words
    }
}

struct SpeechAnalyzerTranscriptUpdate: Equatable, Sendable {
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var isFinal: Bool
    var confidence: TranscriptConfidence
    var resultsFinalizationTime: TimeInterval?
    var fragments: [SpeechAnalyzerTranscriptFragment] = []

    init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isFinal: Bool,
        confidence: TranscriptConfidence,
        resultsFinalizationTime: TimeInterval? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
        self.confidence = confidence
        self.resultsFinalizationTime = resultsFinalizationTime
    }
}

enum SpeechAnalyzerTranscriptAssemblyEvent: Equatable, Sendable {
    case none
    case preview(String)
    case committed(TranscriptSentence, replacing: [UUID] = [])
}

struct SpeechAnalyzerTranscriptAssembler: Sendable {
    private struct PendingUpdate: Sendable {
        var id = UUID()
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: TranscriptConfidence
        var fragments: [SpeechAnalyzerTranscriptFragment] = []
        var isFinal = false
    }

    private static let rangeTolerance: TimeInterval = 0.000_001

    private var committedUpdates: [PendingUpdate] = []
    private var pendingUpdates: [PendingUpdate] = []
    private var stableBoundary: TimeInterval = 0

    mutating func apply(_ update: SpeechAnalyzerTranscriptUpdate) -> SpeechAnalyzerTranscriptAssemblyEvent {
        let cleaned = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .none }
        let pending = PendingUpdate(
            text: cleaned,
            startTime: update.startTime,
            endTime: update.endTime,
            confidence: update.confidence,
            fragments: SpeechAnalyzerTranscriptFragment.wholeWords(update.fragments),
            isFinal: update.isFinal
        )
        let activePending = storePending(pending, isFinal: update.isFinal)
        let finalizesActiveUpdate = update.isFinal
            && Self.sameRange(activePending, pending)
            && activePending.text == pending.text
        if finalizesActiveUpdate || activePending.endTime <= stableBoundary + Self.rangeTolerance {
            return commit(activePending)
        }
        return .preview(previewText)
    }

    var previewText: String {
        pendingUpdates.sorted { $0.startTime < $1.startTime }
            .map(\.text).joined(separator: " ")
    }

    mutating func advanceStableBoundary(to boundary: TimeInterval) -> [SpeechAnalyzerTranscriptAssemblyEvent] {
        guard boundary.isFinite else { return [] }
        stableBoundary = max(stableBoundary, boundary)
        let stableUpdates = pendingUpdates
            .filter { $0.endTime <= stableBoundary + Self.rangeTolerance }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }
        return stableUpdates.compactMap { update in
            let event = commit(update)
            guard case .committed = event else { return nil }
            return event
        }
    }

    mutating func finish() -> [SpeechAnalyzerTranscriptAssemblyEvent] {
        let remainingUpdates = pendingUpdates.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
        return remainingUpdates.compactMap { update in
            var update = update
            update.confidence = .low
            let event = commit(update)
            guard case .committed = event else { return nil }
            return event
        }
    }

    private mutating func storePending(_ update: PendingUpdate, isFinal: Bool) -> PendingUpdate {
        if isFinal {
            pendingUpdates = pendingUpdates.flatMap { existing -> [PendingUpdate] in
                if let remaining = Self.remainingFragments(of: existing, after: update) { return remaining }
                if Self.isCorrectedCoarsePhrase(existing, update) { return [] }
                return [existing]
            }
        }
        if let existing = pendingUpdates.first(where: { Self.shouldKeep($0, over: update) }) {
            return existing
        }
        var activeUpdate = update
        if let existing = pendingUpdates.first(where: { Self.shouldReplace($0, with: update) }) {
            activeUpdate.id = existing.id
        }
        pendingUpdates.removeAll { Self.shouldReplace($0, with: update) }
        pendingUpdates.append(activeUpdate)
        return activeUpdate
    }

    private static func isCorrectedCoarsePhrase(_ existing: PendingUpdate, _ update: PendingUpdate) -> Bool {
        guard existing.fragments.allSatisfy({
                  abs($0.startTime - existing.startTime) <= rangeTolerance
                      && abs($0.endTime - existing.endTime) <= rangeTolerance
              }) else { return false }
        // Native progressive results can timestamp an entire hypothesis as one
        // atomic run, including surrounding silence. The final word-timed result
        // replaces that run even when several words (or a short utterance) change.
        // Recover any identifiable prefix/suffix before retiring this coarse run.
        // Empty fragments are legacy/unattributed input, not evidence of this case.
        // Both boundaries can move after silence is trimmed and the last word
        // completes. Require substantial overlap, not merely touching adjacent
        // speech, when the final range extends beyond the coarse hypothesis.
        let overlap = min(existing.endTime, update.endTime) - max(existing.startTime, update.startTime)
        let shorterDuration = min(existing.endTime - existing.startTime, update.endTime - update.startTime)
        if !existing.fragments.isEmpty, !update.fragments.isEmpty,
           overlap > max(Self.rangeTolerance, shorterDuration / 2) {
            return true
        }
        guard rangeContains(existing, update) else { return false }
        let oldWords = normalized(existing.text).split(separator: " ")
        let newWords = normalized(update.text).split(separator: " ")
        guard min(oldWords.count, newWords.count) >= 3 else { return false }
        if oldWords.count == newWords.count,
           zip(oldWords, newWords).filter({ $0 != $1 }).count <= 1 {
            return true
        }
        var prefixCount = 0
        while prefixCount < min(oldWords.count, newWords.count), oldWords[prefixCount] == newWords[prefixCount] {
            prefixCount += 1
        }
        var suffixCount = 0
        while suffixCount < min(oldWords.count, newWords.count) - prefixCount,
              oldWords[oldWords.count - suffixCount - 1] == newWords[newWords.count - suffixCount - 1] {
            suffixCount += 1
        }
        let oldChangedCount = oldWords.count - prefixCount - suffixCount
        let newChangedCount = newWords.count - prefixCount - suffixCount
        return (1...2).contains(oldChangedCount) && (1...2).contains(newChangedCount)
            && prefixCount + suffixCount >= 2 * max(oldChangedCount, newChangedCount)
    }

    private static func remainingFragments(of existing: PendingUpdate, after update: PendingUpdate) -> [PendingUpdate]? {
        guard !shouldReplace(existing, with: update),
              max(existing.startTime, update.startTime) < min(existing.endTime, update.endTime) else {
            return nil
        }
        if !existing.fragments.isEmpty,
           !existing.fragments.contains(where: { fragment in
               [update.startTime, update.endTime].contains { boundary in
                   fragment.startTime < boundary - rangeTolerance && fragment.endTime > boundary + rangeTolerance
               }
           }) {
            let before = existing.fragments.filter { $0.endTime <= update.startTime + rangeTolerance }
            let after = existing.fragments.filter { $0.startTime >= update.endTime - rangeTolerance }
            return [before, after].compactMap { fragments in
                guard let first = fragments.first, let last = fragments.last else { return nil }
                return PendingUpdate(
                    text: fragments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: first.startTime,
                    endTime: last.endTime,
                    confidence: existing.confidence,
                    fragments: fragments
                )
            }
        }
        let words = existing.text.split(whereSeparator: \.isWhitespace)
        let finalizedWords = update.text.split(whereSeparator: \.isWhitespace)
        guard finalizedWords.count < words.count else { return nil }
        if abs(existing.startTime - update.startTime) <= rangeTolerance,
           zip(words.prefix(finalizedWords.count), finalizedWords).allSatisfy({ normalized(String($0)) == normalized(String($1)) }) {
            return [PendingUpdate(
                text: String(existing.text[words[finalizedWords.count].startIndex...]),
                startTime: update.endTime,
                endTime: existing.endTime,
                confidence: existing.confidence
            )]
        }
        if abs(existing.endTime - update.endTime) <= rangeTolerance,
           zip(words.suffix(finalizedWords.count), finalizedWords).allSatisfy({ normalized(String($0)) == normalized(String($1)) }) {
            return [PendingUpdate(
                text: String(existing.text[..<words[words.count - finalizedWords.count].startIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: existing.startTime,
                endTime: update.startTime,
                confidence: existing.confidence
            )]
        }
        return nil
    }

    private mutating func commit(_ update: PendingUpdate) -> SpeechAnalyzerTranscriptAssemblyEvent {
        let startTime = max(0, Int(update.startTime.rounded(.down)))
        let endTime = max(startTime + 1, Int(update.endTime.rounded(.up)))
        if let existingIndex = committedUpdates.firstIndex(where: {
            Self.sameRange($0, update) && $0.text == update.text
        }) {
            committedUpdates[existingIndex].isFinal = committedUpdates[existingIndex].isFinal || update.isFinal
            pendingUpdates.removeAll { existing in
                existing.id == update.id
            }
            return .none
        }
        if committedUpdates.contains(where: { Self.shouldKeep($0, over: update) }) {
            pendingUpdates.removeAll { $0.id == update.id }
            return .none
        }
        let replaced = committedUpdates.filter {
            (update.isFinal || !$0.isFinal) && Self.shouldReplace($0, with: update)
        }
        var update = update
        if let existing = replaced.first {
            update.id = existing.id
        }
        committedUpdates.removeAll { existing in replaced.contains { $0.id == existing.id } }
        pendingUpdates.removeAll { Self.shouldReplace($0, with: update) }
        committedUpdates.append(update)
        return .committed(
            TranscriptSentence(
                id: update.id,
                startTime: startTime,
                endTime: endTime,
                text: update.text,
                translation: "",
                confidence: update.confidence,
                sourceStartTime: update.startTime
            ),
            replacing: replaced.map(\.id)
        )
    }

    private static func shouldKeep(_ existing: PendingUpdate, over update: PendingUpdate) -> Bool {
        !sameRange(existing, update)
            && rangeContains(existing, update)
            && (
                normalized(existing.text) == normalized(update.text)
                    || normalized(existing.text).hasPrefix(normalized(update.text) + " ")
            )
    }

    private static func shouldReplace(_ existing: PendingUpdate, with update: PendingUpdate) -> Bool {
        sameRange(existing, update)
            || rangeContains(update, existing)
    }

    private static func sameRange(_ lhs: PendingUpdate, _ rhs: PendingUpdate) -> Bool {
        abs(lhs.startTime - rhs.startTime) <= rangeTolerance
            && abs(lhs.endTime - rhs.endTime) <= rangeTolerance
    }

    private static func rangeContains(_ lhs: PendingUpdate, _ rhs: PendingUpdate) -> Bool {
        lhs.startTime <= rhs.startTime + rangeTolerance
            && lhs.endTime + rangeTolerance >= rhs.endTime
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map {
                String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

actor SpeechAnalyzerTranscriptAssemblyStore {
    private var assembler = SpeechAnalyzerTranscriptAssembler()
    private var isFinished = false
    private var sentences: [TranscriptSentence] = []

    func apply(_ update: SpeechAnalyzerTranscriptUpdate) -> [SpeechAnalyzerTranscriptAssemblyEvent] {
        guard !isFinished else { return [] }
        var events: [SpeechAnalyzerTranscriptAssemblyEvent] = []
        let event = assembler.apply(update)
        if case .committed = event {
            events.append(event)
        }
        if let boundary = update.resultsFinalizationTime {
            events += assembler.advanceStableBoundary(to: boundary)
        }
        events.append(.preview(assembler.previewText))
        retain(events)
        return events
    }

    func finish() -> [SpeechAnalyzerTranscriptAssemblyEvent] {
        guard !isFinished else { return [] }
        isFinished = true
        let events = assembler.finish() + [.preview("")]
        retain(events)
        return events
    }

    func snapshot() -> [TranscriptSentence] {
        sentences
    }

    private func retain(_ events: [SpeechAnalyzerTranscriptAssemblyEvent]) {
        for case let .committed(sentence, replacing) in events {
            sentences.removeAll { $0.id == sentence.id || replacing.contains($0.id) }
            sentences.append(sentence)
        }
        sentences.sort { $0.precedes($1) }
    }
}

public final class NativeSpeechLiveTranscriber: LiveTranscriptionRunning, @unchecked Sendable {
    private struct Resources: Sendable {
        var inputPipe: SpeechAnalyzerInputPipe?
        var analysisTask: Task<Void, Never>?
        var resultTask: Task<[TranscriptSentence], Never>?
        var assemblyStore: SpeechAnalyzerTranscriptAssemblyStore?
    }

    private let locale: Locale
    private let stateQueue = DispatchQueue(label: "app.livenotes.native-live-transcriber.state")
    private var inputPipe: SpeechAnalyzerInputPipe?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<[TranscriptSentence], Never>?
    private var assemblyStore: SpeechAnalyzerTranscriptAssemblyStore?
    private var eventHandler: (@Sendable (LiveTranscriptionEvent) -> Void)?
    private var analysisAudioFormat: AVAudioFormat?
    private var liveInputConverter: SpeechAnalyzerLiveInputConverter?
    private var isPaused = false
    private var audioFormatFailureReported = false

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public func start(
        eventHandler: @escaping @Sendable (LiveTranscriptionEvent) -> Void
    ) async throws {
        try Task.checkCancellation()
        cancel()
        try await ensureSpeechRecognitionAccess()
        try Task.checkCancellation()
        let transcriber = try await NativeSpeechAnalyzer.makeTranscriber(locale: locale, live: true)
        try Task.checkCancellation()
        let modules: [any SpeechModule] = [transcriber]
        let analysisAudioFormat = try await NativeSpeechAnalyzer.analysisFormat(for: modules)
        try Task.checkCancellation()
        speechPipelineLogger.info("Live transcription started with \(SpeechPipelineLog.formatDescription(analysisAudioFormat), privacy: .public).")
        let inputPipe = SpeechAnalyzerInputPipe()
        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let assemblyStore = SpeechAnalyzerTranscriptAssemblyStore()
        let emitEvents: @Sendable ([SpeechAnalyzerTranscriptAssemblyEvent]) -> Void = { events in
            for event in events {
                switch event {
                case .none:
                    break
                case let .preview(text):
                    eventHandler(.partialTranscript(text))
                case let .committed(sentence, replacing):
                    eventHandler(.committedTranscript(sentence, replacing: replacing))
                }
            }
        }
        let resultTask = Task.detached(priority: .userInitiated) { () -> [TranscriptSentence] in
            do {
                for try await result in transcriber.results {
                    let update = SpeechAnalyzerTranscriptUpdate(result: result)
                    await emitEvents(assemblyStore.apply(update))
                }
            } catch is CancellationError {
            } catch {
                speechPipelineLogger.error("Live transcription result stream failed: \(SpeechPipelineLog.errorDescription(error), privacy: .public)")
                eventHandler(.failed("Live speech recognition failed."))
            }
            await emitEvents(assemblyStore.finish())
            return await assemblyStore.snapshot()
        }
        let analysisTask = Task.detached(priority: .userInitiated) {
            do {
                try await analyzer.prepareToAnalyze(in: analysisAudioFormat)
                _ = try await analyzer.analyzeSequence(inputPipe.stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch is CancellationError {
            } catch {
                speechPipelineLogger.error("Live transcription audio analysis failed: \(SpeechPipelineLog.errorDescription(error), privacy: .public)")
                eventHandler(.failed("Live speech recognition failed."))
            }
        }
        let installed = stateQueue.sync {
            guard !Task.isCancelled else { return false }
            self.eventHandler = eventHandler
            self.inputPipe = inputPipe
            self.analysisTask = analysisTask
            self.resultTask = resultTask
            self.assemblyStore = assemblyStore
            self.analysisAudioFormat = analysisAudioFormat
            self.liveInputConverter = SpeechAnalyzerLiveInputConverter(targetFormat: analysisAudioFormat)
            self.isPaused = false
            self.audioFormatFailureReported = false
            return true
        }
        guard installed else {
            inputPipe.finish()
            analysisTask.cancel()
            resultTask.cancel()
            throw CancellationError()
        }
        eventHandler(.ready)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        var pipe: SpeechAnalyzerInputPipe?
        var input: AnalyzerInput?
        var failureHandler: (@Sendable (LiveTranscriptionEvent) -> Void)?
        stateQueue.sync {
            guard !isPaused, let inputPipe, let analysisAudioFormat, let liveInputConverter else { return }
            guard let analyzerInput = liveInputConverter.input(from: buffer) else {
                if !audioFormatFailureReported {
                    audioFormatFailureReported = true
                    failureHandler = eventHandler
                    speechPipelineLogger.error("Live transcription could not convert microphone audio from \(SpeechPipelineLog.formatDescription(buffer.format), privacy: .public) to \(SpeechPipelineLog.formatDescription(analysisAudioFormat), privacy: .public).")
                }
                return
            }
            pipe = inputPipe
            input = analyzerInput
        }
        if let input {
            pipe?.yield(input)
        }
        failureHandler?(.failed("Live speech recognition could not process microphone audio."))
    }

    public func pause() {
        stateQueue.sync {
            guard !isPaused else { return }
            isPaused = true
        }
    }

    public func resume() {
        stateQueue.sync {
            guard isPaused else { return }
            isPaused = false
        }
    }

    public func finish() async -> [TranscriptSentence] {
        let resources = takeResources()
        resources.inputPipe?.finish()
        return await Self.drain(
            analysisTask: resources.analysisTask,
            resultTask: resources.resultTask,
            assemblyStore: resources.assemblyStore,
            timeoutSeconds: 5
        )
    }

    public func cancel() {
        let resources = takeResources()
        resources.inputPipe?.finish()
        resources.analysisTask?.cancel()
        resources.resultTask?.cancel()
    }

    private func takeResources() -> Resources {
        stateQueue.sync {
            let resources = Resources(
                inputPipe: inputPipe,
                analysisTask: analysisTask,
                resultTask: resultTask,
                assemblyStore: assemblyStore
            )
            inputPipe = nil
            analysisTask = nil
            resultTask = nil
            assemblyStore = nil
            eventHandler = nil
            analysisAudioFormat = nil
            liveInputConverter = nil
            isPaused = false
            audioFormatFailureReported = false
            return resources
        }
    }

    static func drain(
        analysisTask: Task<Void, Never>?,
        resultTask: Task<[TranscriptSentence], Never>?,
        assemblyStore: SpeechAnalyzerTranscriptAssemblyStore?,
        timeoutSeconds: TimeInterval
    ) async -> [TranscriptSentence] {
        guard analysisTask != nil || resultTask != nil else {
            _ = await assemblyStore?.finish()
            return await assemblyStore?.snapshot() ?? []
        }
        let transcript = await withCheckedContinuation { continuation in
            let completion = LiveTranscriptDrainCompletion(continuation)
            Task {
                await analysisTask?.value
                let transcript: [TranscriptSentence]
                if let resultTask {
                    transcript = await resultTask.value
                } else {
                    transcript = await assemblyStore?.snapshot() ?? []
                }
                completion.resume(returning: transcript)
            }
            Task {
                let nanoseconds = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                completion.resume(returning: await assemblyStore?.snapshot() ?? [])
            }
        }
        analysisTask?.cancel()
        resultTask?.cancel()
        _ = await assemblyStore?.finish()
        return await assemblyStore?.snapshot() ?? transcript
    }

    private func ensureSpeechRecognitionAccess() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            if status == .authorized {
                return
            }
            throw RecordingPipelineError.speechRecognitionAccessDenied
        case .denied, .restricted:
            throw RecordingPipelineError.speechRecognitionAccessDenied
        @unknown default:
            throw RecordingPipelineError.speechRecognitionAccessDenied
        }
    }
}

final class SpeechAnalyzerInputPipe: @unchecked Sendable {
    let stream: AsyncStream<AnalyzerInput>
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(
        bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy = .unbounded
    ) {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        stream = AsyncStream(bufferingPolicy: bufferingPolicy) { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation
    }

    func yield(_ input: AnalyzerInput) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(input)
    }

    func finish() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish()
    }
}

private final class LiveTranscriptDrainCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSentence], Never>?

    init(_ continuation: CheckedContinuation<[TranscriptSentence], Never>) {
        self.continuation = continuation
    }

    func resume(returning transcript: [TranscriptSentence]) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: transcript)
    }
}

private enum AudioBufferCopier {
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else {
                continue
            }
            memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
        }
        return copy
    }
}

final class SpeechAnalyzerLiveInputConverter: @unchecked Sendable {
    private struct FormatSignature: Equatable {
        var commonFormat: AVAudioCommonFormat
        var sampleRate: Double
        var channelCount: AVAudioChannelCount
        var isInterleaved: Bool

        init(_ format: AVAudioFormat) {
            commonFormat = format.commonFormat
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            isInterleaved = format.isInterleaved
        }
    }

    private let targetFormat: AVAudioFormat
    private var sourceSignature: FormatSignature?
    private var converter: AVAudioConverter?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func input(from buffer: AVAudioPCMBuffer) -> AnalyzerInput? {
        guard let convertedBuffer = convert(buffer) else {
            return nil
        }
        return AnalyzerInput(buffer: convertedBuffer)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else {
            return AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 0)
        }
        if SpeechAnalyzerAudioConverter.matches(buffer.format, targetFormat) {
            return AudioBufferCopier.copy(buffer)
        }
        let signature = FormatSignature(buffer.format)
        if sourceSignature != signature {
            sourceSignature = signature
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else {
            return nil
        }
        let capacity = SpeechAnalyzerAudioConverter.convertedFrameCapacity(
            sourceFrameLength: buffer.frameLength,
            sourceSampleRate: buffer.format.sampleRate,
            targetSampleRate: targetFormat.sampleRate
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        let inputProvider = AudioConverterInputProvider(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            inputProvider.nextBuffer(inputStatus)
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0 else {
            return nil
        }
        return converted
    }

}

enum SpeechAnalyzerAudioConverter {
    static func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else {
            return AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 0)
        }
        if matches(buffer.format, targetFormat) {
            return AudioBufferCopier.copy(buffer)
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }
        let capacity = convertedFrameCapacity(
            sourceFrameLength: buffer.frameLength,
            sourceSampleRate: buffer.format.sampleRate,
            targetSampleRate: targetFormat.sampleRate
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        let inputProvider = AudioConverterInputProvider(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            inputProvider.nextBuffer(inputStatus)
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0 else {
            return nil
        }
        return converted
    }

    static func matches(_ source: AVAudioFormat, _ target: AVAudioFormat) -> Bool {
        source.commonFormat == target.commonFormat
            && source.sampleRate == target.sampleRate
            && source.channelCount == target.channelCount
            && source.isInterleaved == target.isInterleaved
    }

    static func convertedFrameCapacity(
        sourceFrameLength: AVAudioFrameCount,
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> AVAudioFrameCount {
        let ratio = targetSampleRate / max(sourceSampleRate, 1)
        let frameCount = ceil(Double(sourceFrameLength) * ratio)
        return AVAudioFrameCount(max(1, frameCount + 128))
    }
}

private enum SpeechPipelineLog {
    static func formatDescription(_ format: AVAudioFormat) -> String {
        let commonFormat: String
        switch format.commonFormat {
        case .pcmFormatFloat32:
            commonFormat = "Float32"
        case .pcmFormatFloat64:
            commonFormat = "Float64"
        case .pcmFormatInt16:
            commonFormat = "Int16"
        case .pcmFormatInt32:
            commonFormat = "Int32"
        case .otherFormat:
            commonFormat = "Other"
        @unknown default:
            commonFormat = "Unknown"
        }
        return "\(format.channelCount) channel \(Int(format.sampleRate)) Hz \(commonFormat)"
    }

    static func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

private enum NativeSpeechAnalyzer {
    static func makeTranscriber(locale: Locale, live: Bool) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw RecordingPipelineError.runtimeFailed("English speech transcription is not available.")
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw RecordingPipelineError.runtimeFailed("English speech transcription is not available.")
        }
        let preset: SpeechTranscriber.Preset = live
            ? .timeIndexedProgressiveTranscription
            : .timeIndexedTranscriptionWithAlternatives
        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: preset)
        try await ensureAssets(for: [transcriber])
        return transcriber
    }

    static func analysisFormat(for modules: [any SpeechModule]) async throws -> AVAudioFormat {
        if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) {
            return format
        }
        throw RecordingPipelineError.runtimeFailed("English speech transcription could not prepare audio.")
    }

    static func ensureAssets(for modules: [any SpeechModule]) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw RecordingPipelineError.runtimeFailed("English speech transcription assets are not supported on this Mac.")
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw RecordingPipelineError.runtimeFailed("English speech transcription assets are not installed.")
            }
        @unknown default:
            throw RecordingPipelineError.runtimeFailed("English speech transcription assets are not available.")
        }
    }
}

extension SpeechAnalyzerTranscriptUpdate {
    init(result: SpeechTranscriber.Result) {
        let start = Self.safeSeconds(result.range.start.seconds, fallback: 0)
        let end = Self.safeSeconds(CMTimeRangeGetEnd(result.range).seconds, fallback: start + 1)
        self.init(
            text: String(result.text.characters),
            startTime: start,
            endTime: max(start + 0.000_001, end),
            isFinal: result.isFinal,
            confidence: result.isFinal ? .high : .medium,
            resultsFinalizationTime: result.resultsFinalizationTime.seconds
        )
        var leadingText = ""
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            if let range = run.audioTimeRange {
                fragments.append(SpeechAnalyzerTranscriptFragment(
                    text: leadingText + text,
                    startTime: range.start.seconds,
                    endTime: CMTimeRangeGetEnd(range).seconds
                ))
                leadingText = ""
            } else if !fragments.isEmpty {
                fragments[fragments.count - 1].text += text
            } else {
                leadingText += text
            }
        }
    }

    private static func safeSeconds(_ seconds: Double, fallback: Double) -> Double {
        seconds.isFinite ? max(0, seconds) : fallback
    }
}

public enum TranscriptFinalizationPolicy {
    public static func chooseTranscript(
        generated: [TranscriptSentence],
        live: [TranscriptSentence]
    ) -> [TranscriptSentence] {
        let generated = sanitized(generated)
        let live = sanitized(live)
        guard !live.isEmpty else { return generated }
        guard !generated.isEmpty else { return live }
        let generatedScore = TranscriptScore(generated)
        let liveScore = TranscriptScore(live)
        if generatedScore.wordCount * 4 < liveScore.wordCount * 3 {
            return live
        }
        if generatedScore.coveredSeconds + 3 < liveScore.coveredSeconds {
            return live
        }
        if generatedScore.segmentCount * 2 < liveScore.segmentCount,
           generatedScore.wordCount <= liveScore.wordCount {
            return live
        }
        return generated
    }

    private static func sanitized(_ transcript: [TranscriptSentence]) -> [TranscriptSentence] {
        transcript.compactMap { sentence in
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let startTime = max(0, sentence.startTime)
            return TranscriptSentence(
                id: sentence.id,
                startTime: startTime,
                endTime: max(startTime + 1, sentence.endTime),
                text: text,
                translation: sentence.translation.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: sentence.confidence,
                sourceStartTime: sentence.sourceStartTime
            )
        }
    }

    private struct TranscriptScore {
        var wordCount: Int
        var coveredSeconds: Int
        var segmentCount: Int

        init(_ transcript: [TranscriptSentence]) {
            wordCount = transcript.reduce(0) { partial, sentence in
                partial + sentence.text.split(whereSeparator: \.isWhitespace).count
            }
            segmentCount = transcript.count
            coveredSeconds = Self.coveredSeconds(transcript)
        }

        private static func coveredSeconds(_ transcript: [TranscriptSentence]) -> Int {
            let ranges = transcript
                .map { (start: max(0, $0.startTime), end: max($0.startTime + 1, $0.endTime)) }
                .sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.end < rhs.end
                    }
                    return lhs.start < rhs.start
                }
            var total = 0
            var current: (start: Int, end: Int)?
            for range in ranges {
                guard let currentRange = current else {
                    current = range
                    continue
                }
                if range.start <= currentRange.end {
                    current = (currentRange.start, max(currentRange.end, range.end))
                } else {
                    total += max(0, currentRange.end - currentRange.start)
                    current = range
                }
            }
            if let current {
                total += max(0, current.end - current.start)
            }
            return total
        }
    }
}

enum TranscriptUtteranceSegmenter {
    enum TranslationMode {
        case retranslateMergedUtterances
        case preserveMergedTranslations
    }

    private static let pauseBoundarySeconds = 2
    private static let maximumWords = 44
    private static let maximumDurationSeconds = 24

    static func segment(
        _ transcript: [TranscriptSentence],
        translationMode: TranslationMode = .retranslateMergedUtterances
    ) -> [TranscriptSentence] {
        let fragments = transcript
            .compactMap(sanitizedFragment)
            .sorted { $0.precedes($1) }
        var utterances: [TranscriptSentence] = []
        var pending: PendingUtterance?

        for fragment in fragments {
            guard let current = pending else {
                pending = PendingUtterance(fragment, translationMode: translationMode)
                continue
            }
            if shouldStartNewUtterance(
                after: current,
                before: fragment,
                translationMode: translationMode
            ) {
                utterances.append(current.sentence())
                pending = PendingUtterance(fragment, translationMode: translationMode)
            } else {
                pending?.append(fragment)
            }
        }
        if let pending {
            utterances.append(pending.sentence())
        }
        return utterances
    }

    private static func sanitizedFragment(_ sentence: TranscriptSentence) -> TranscriptSentence? {
        let text = normalizedText(sentence.text)
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .alphanumerics) != nil else {
            return nil
        }
        let startTime = max(0, sentence.startTime)
        let endTime = max(startTime + 1, sentence.endTime)
        return TranscriptSentence(
            id: sentence.id,
            startTime: startTime,
            endTime: endTime,
            text: text,
            translation: sentence.translation.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: sentence.confidence,
            sourceStartTime: sentence.sourceStartTime
        )
    }

    private static func shouldStartNewUtterance(
        after current: PendingUtterance,
        before next: TranscriptSentence,
        translationMode: TranslationMode
    ) -> Bool {
        let nextHasTranslation = !next.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if translationMode == .preserveMergedTranslations,
           current.hasTranslation != nextHasTranslation {
            return true
        }
        if next.startTime < current.endTime,
           shouldMergeOverlappingShortLatinFragment(current.text, wordCount: current.wordCount) {
            return false
        }
        if next.startTime - current.endTime >= pauseBoundarySeconds {
            return true
        }
        if endsWithSentenceTerminator(current.text) {
            return true
        }
        if current.durationSeconds >= maximumDurationSeconds,
           current.wordCount >= 12 {
            return true
        }
        if current.wordCount >= maximumWords {
            return true
        }
        if current.wordCount + wordCount(next.text) > maximumWords,
           hasClauseBoundary(current.text) {
            return true
        }
        return false
    }

    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func isShortLatinFragment(_ text: String, wordCount: Int) -> Bool {
        wordCount <= 5 && text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }

    private static func shouldMergeOverlappingShortLatinFragment(_ text: String, wordCount: Int) -> Bool {
        guard isShortLatinFragment(text, wordCount: wordCount) else { return false }
        guard endsWithSentenceTerminator(text) else { return true }
        return isAudienceAddressLeadIn(text)
    }

    private static func isAudienceAddressLeadIn(_ text: String) -> Bool {
        let fragment = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return [
            "all right class",
            "no class",
            "now class",
            "ok class",
            "okay class",
            "yeah class"
        ].contains(fragment)
    }

    private static func endsWithSentenceTerminator(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?。？！".contains(last)
    }

    private static func hasClauseBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ",;:，；：".contains(last) || endsWithSentenceTerminator(text)
    }

    private struct PendingUtterance {
        private let firstID: UUID
        private let sourceStartTime: Double?
        private(set) var startTime: Int
        private(set) var endTime: Int
        private(set) var text: String
        private(set) var wordCount: Int
        private var fragmentCount: Int
        private var confidence: TranscriptConfidence
        private var translation: String
        private let translationMode: TranslationMode

        init(_ fragment: TranscriptSentence, translationMode: TranslationMode) {
            firstID = fragment.id
            sourceStartTime = fragment.sourceStartTime
            startTime = fragment.startTime
            endTime = fragment.endTime
            text = fragment.text
            wordCount = TranscriptUtteranceSegmenter.wordCount(fragment.text)
            fragmentCount = 1
            confidence = fragment.confidence
            translation = fragment.translation
            self.translationMode = translationMode
        }

        var durationSeconds: Int {
            max(0, endTime - startTime)
        }

        var hasTranslation: Bool {
            !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        mutating func append(_ fragment: TranscriptSentence) {
            text = TranscriptUtteranceSegmenter.normalizedText("\(text) \(fragment.text)")
            endTime = max(endTime, fragment.endTime)
            wordCount += TranscriptUtteranceSegmenter.wordCount(fragment.text)
            fragmentCount += 1
            confidence = mergedConfidence(confidence, fragment.confidence)
            switch translationMode {
            case .retranslateMergedUtterances:
                translation = ""
            case .preserveMergedTranslations:
                let nextTranslation = fragment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                if translation.isEmpty || nextTranslation.isEmpty {
                    translation = ""
                } else {
                    translation = TranscriptUtteranceSegmenter.normalizedText("\(translation) \(nextTranslation)")
                }
            }
        }

        func sentence() -> TranscriptSentence {
            TranscriptSentence(
                id: fragmentCount == 1 ? firstID : UUID(),
                startTime: startTime,
                endTime: max(startTime + 1, endTime),
                text: text,
                translation: translation,
                confidence: confidence,
                sourceStartTime: sourceStartTime
            )
        }

        private func mergedConfidence(
            _ lhs: TranscriptConfidence,
            _ rhs: TranscriptConfidence
        ) -> TranscriptConfidence {
            if lhs == .low || rhs == .low {
                return .low
            }
            if lhs == .medium || rhs == .medium {
                return .medium
            }
            return .high
        }
    }
}

public struct NativeSpeechInferenceRunner: RecordingInferenceRunning {
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public func process(audioURL: URL, artifactsRootURL: URL) throws -> RecordingPipelineOutput {
        let startedAt = Date()
        let audioDurationSeconds = try Self.audioDurationSeconds(for: audioURL)
        let rawSentences = try transcribe(audioURL: audioURL)
        let sentences = TranscriptUtteranceSegmenter.segment(rawSentences)
        let totalSeconds = Date().timeIntervalSince(startedAt)
        speechPipelineLogger.info("Final transcription segmented \(rawSentences.count, privacy: .public) speech results into \(sentences.count, privacy: .public) utterances.")
        return RecordingPipelineOutput(
            transcript: sentences,
            metrics: RecordingPipelineMetrics(
                audioDurationSeconds: audioDurationSeconds,
                transcriptSegments: sentences.count,
                translationSegments: sentences.filter { !$0.translation.isEmpty }.count,
                transcriptionProcessingSeconds: totalSeconds,
                totalProcessingSeconds: totalSeconds,
                realTimeFactor: totalSeconds / max(audioDurationSeconds, 1)
            )
        )
    }

    private func transcribe(audioURL: URL) throws -> [TranscriptSentence] {
        let locale = locale
        return try AsyncThrowingResultBox.run(timeoutSeconds: 300) {
            try await Self.transcribeWithSpeechAnalyzer(audioURL: audioURL, locale: locale)
        }
    }

    private static func transcribeWithSpeechAnalyzer(audioURL: URL, locale: Locale) async throws -> [TranscriptSentence] {
        try await ensureSpeechRecognitionAccess()
        let audioFile = try AVAudioFile(forReading: audioURL)
        let transcriber = try await NativeSpeechAnalyzer.makeTranscriber(locale: locale, live: false)
        let modules: [any SpeechModule] = [transcriber]
        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let audioDurationSeconds = Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)
        speechPipelineLogger.info("Final transcription started from audio file: duration \(audioDurationSeconds, privacy: .public) seconds, format \(SpeechPipelineLog.formatDescription(audioFile.processingFormat), privacy: .public).")
        let resultTask = Task<[TranscriptSentence], Error> {
            let assemblyStore = SpeechAnalyzerTranscriptAssemblyStore()
            for try await result in transcriber.results {
                let update = SpeechAnalyzerTranscriptUpdate(result: result)
                _ = await assemblyStore.apply(update)
            }
            _ = await assemblyStore.finish()
            return await assemblyStore.snapshot()
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let sentences = try await resultTask.value
            speechPipelineLogger.info("Final transcription finished with \(sentences.count, privacy: .public) transcript segments.")
            return sentences
        } catch {
            resultTask.cancel()
            speechPipelineLogger.error("Final transcription failed: \(SpeechPipelineLog.errorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func ensureSpeechRecognitionAccess() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            if status == .authorized {
                return
            }
            throw RecordingPipelineError.speechRecognitionAccessDenied
        case .denied, .restricted:
            throw RecordingPipelineError.speechRecognitionAccessDenied
        @unknown default:
            throw RecordingPipelineError.speechRecognitionAccessDenied
        }
    }

    private static func audioDurationSeconds(for audioURL: URL) throws -> Double {
        let audioFile = try AVAudioFile(forReading: audioURL)
        return Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)
    }
}

private final class AsyncThrowingResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    static func run(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = AsyncThrowingResultBox<Value>()
        Task.detached(priority: .userInitiated) {
            do {
                box.complete(.success(try await operation()))
            } catch {
                box.complete(.failure(error))
            }
        }
        return try box.wait(timeoutSeconds: timeoutSeconds)
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeoutSeconds: TimeInterval) throws -> Value {
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            throw RecordingPipelineError.runtimeFailed("Native speech transcription timed out.")
        }
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case nil:
            throw RecordingPipelineError.runtimeFailed("Native speech transcription failed.")
        }
    }
}

public struct RecordingPipelineReadinessReport: Codable, Equatable, Sendable {
    public var audioCapture: String
    public var speechRecognition: String
    public var translation: String
    public var savedTranscript: String
    public var endToEndRecordingPipeline: String
    public var processingRuntime: String
    public var metrics: RecordingPipelineMetrics

    public init(
        audioCapture: String,
        speechRecognition: String,
        translation: String,
        savedTranscript: String,
        endToEndRecordingPipeline: String,
        processingRuntime: String,
        metrics: RecordingPipelineMetrics
    ) {
        self.audioCapture = audioCapture
        self.speechRecognition = speechRecognition
        self.translation = translation
        self.savedTranscript = savedTranscript
        self.endToEndRecordingPipeline = endToEndRecordingPipeline
        self.processingRuntime = processingRuntime
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
