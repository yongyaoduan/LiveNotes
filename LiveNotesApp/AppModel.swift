import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var store: SessionStore
    @Published var newRecordingSheetVisible = false
    @Published var consentSheetVisible = false
    @Published var stopConfirmationVisible = false
    @Published var consentAccepted = false
    @Published var recordingName = "Untitled Recording"
    @Published var currentTopicTitle = "Decision Point"
    @Published var localModelStatus: String
    @Published var recordingEngineStatus: String
    @Published var persistenceStatus: String?
    @Published var exportStatus: String?

    private let sessionFileStore: SessionFileStore?
    private let fixtureRecordingEnabled: Bool
    private let audioRecorder: AudioRecordingControlling?
    private let inferenceRunner: (any RecordingInferenceRunning)?
    private let inferenceArtifactsRootURL: URL?
    private var cachedReadyArtifactsRootURL: URL?
    private var finalizingDurations: [UUID: Int] = [:]
    private var recordingClocks: [UUID: RecordingClock] = [:]
    private var activeAudioURLs: [UUID: URL] = [:]
    private var liveDurationTask: Task<Void, Never>?

    init(
        store: SessionStore,
        sessionFileStore: SessionFileStore? = nil,
        localModelStatus: String = "Ready",
        recordingEngineStatus: String = "Ready",
        fixtureRecordingEnabled: Bool = false,
        audioRecorder: AudioRecordingControlling? = nil,
        inferenceRunner: (any RecordingInferenceRunning)? = nil,
        inferenceArtifactsRootURL: URL? = nil
    ) {
        self.store = store
        self.sessionFileStore = sessionFileStore
        self.localModelStatus = localModelStatus
        self.recordingEngineStatus = recordingEngineStatus
        self.fixtureRecordingEnabled = fixtureRecordingEnabled
        self.audioRecorder = audioRecorder
        self.inferenceRunner = inferenceRunner
        self.inferenceArtifactsRootURL = inferenceArtifactsRootURL
        resumeRecordingClocksForLoadedSessions()
        startLiveDurationUpdates()
    }

    static func launchModel(arguments: [String]) -> AppModel {
        if arguments.contains("--ui-test") {
            return uiTestModel(arguments: arguments)
        }
        let fileStore = SessionFileStore(url: sessionStoreURL(arguments: arguments))
        let loadResult = fileStore.loadPreservingCorruptFile()
        var store = SessionStore(
            sessions: loadResult.sessions,
            selectedSessionID: loadResult.sessions.first?.id
        )
        let recoveredCount = store.recoverInterruptedSessions()
        let helperURL = recordingPipelineHelperURL()
        let pythonExecutable = productionPythonExecutable()
        let modelReadiness = bundledModelReadiness()
        let model = AppModel(
            store: store,
            sessionFileStore: fileStore,
            localModelStatus: modelReadiness.userFacingStatus,
            recordingEngineStatus: productionRecordingEngineStatus(
                helperURL: helperURL,
                pythonExecutable: pythonExecutable
            ),
            audioRecorder: AVAudioRecordingEngine(),
            inferenceRunner: helperURL.map {
                LocalMLXInferenceRunner(
                    pythonExecutable: pythonExecutable,
                    helperScriptURL: $0
                )
            }
        )
        model.cachedReadyArtifactsRootURL = modelReadiness.readyRoot
        if recoveredCount > 0 {
            try? fileStore.save(store.sessions)
            model.persistenceStatus = "Recovered unfinished recordings."
            model.retryRecoveredInferenceIfReady()
        } else {
            model.persistenceStatus = loadResult.recovery?.message
        }
        return model
    }

    private static func uiTestModel(arguments: [String]) -> AppModel {
        let localModelStatus = uiModelStatus(arguments: arguments)
        let store: SessionStore
        switch argumentValue("--ui-state", in: arguments) {
        case "saved":
            store = DemoData.savedStore()
        case "live":
            store = DemoData.liveStore()
        case "paused":
            store = DemoData.pausedStore()
        case "preparing":
            store = DemoData.preparingStore()
        case "failed":
            store = DemoData.failedStore()
        case "finalizing-complete":
            store = DemoData.finalizingCompleteStore()
        case "recovered":
            store = DemoData.recoveredStore()
        case "empty":
            store = DemoData.emptyStore()
        default:
            store = DemoData.homeStore()
        }
        let fileStore = uiTestSessionFileStore(arguments: arguments)
        let simulatedRuntime = argumentValue("--ui-recording-runtime", in: arguments) == "simulated"
        try? fileStore?.save(store.sessions)
        let model = AppModel(
            store: store,
            sessionFileStore: fileStore,
            localModelStatus: localModelStatus,
            fixtureRecordingEnabled: !simulatedRuntime,
            audioRecorder: simulatedRuntime ? UITestAudioRecorder() : nil,
            inferenceRunner: simulatedRuntime ? UITestInferenceRunner() : nil,
            inferenceArtifactsRootURL: simulatedRuntime ? FileManager.default.temporaryDirectory : nil
        )
        if simulatedRuntime {
            model.createRecoveredAudioFixtures()
        }
        if simulatedRuntime, argumentValue("--ui-retry-recovered", in: arguments) == "true" {
            model.retryRecoveredInferenceIfReady()
        }
        return model
    }

    var selectedSession: RecordingSession? {
        guard let selectedSessionID = store.selectedSessionID else {
            return nil
        }
        return store.session(id: selectedSessionID)
    }

    var sessionTitle: String {
        selectedSession?.title ?? "Select a recording"
    }

    var canRequestRecording: Bool {
        activeRecordingReason == nil && recordingUnavailableReason == nil
    }

    var canShowNewRecording: Bool {
        activeRecordingReason == nil
    }

    var newRecordingUnavailableReason: String? {
        activeRecordingReason ?? recordingUnavailableReason
    }

    var recordingUnavailableReason: String? {
        if localModelStatus != "Ready" {
            return "Required local models are not ready: whisper-large-v3-turbo and Qwen3-4B-4bit."
        }
        if recordingEngineStatus != "Ready" {
            return recordingEngineStatus
        }
        if persistenceStatus == "Could not save library." {
            return persistenceStatus
        }
        return nil
    }

    private var activeRecordingReason: String? {
        store.sessions.contains { $0.status.blocksNewRecording }
            ? "Finish the current recording before starting another."
            : nil
    }

    func select(_ session: RecordingSession) {
        var updatedStore = store
        try? updatedStore.selectSession(session.id)
        store = updatedStore
    }

    func selectActiveRecording() {
        guard let session = store.sessions.first(where: { $0.status.blocksNewRecording }) else {
            return
        }
        select(session)
    }

    func showNewRecording() {
        guard canShowNewRecording else { return }
        recordingName = "Untitled Recording"
        consentAccepted = false
        newRecordingSheetVisible = true
    }

    func requestRecordingConsent() {
        guard canRequestRecording else { return }
        newRecordingSheetVisible = false
        Task { @MainActor [weak self] in
            self?.consentSheetVisible = true
        }
    }

    func startRecording() {
        guard canRequestRecording else { return }
        let title = recordingName.isEmpty ? "Untitled Recording" : recordingName
        let id = UUID()
        let audioFileName = audioFileName(for: id)
        let audioURL = sessionFileStore?.localFileURL(relativePath: audioFileName)
        var updatedStore = store
        let session = updatedStore.createRecording(
            id: id,
            named: title,
            audioFileName: audioFileName
        )
        if !fixtureRecordingEnabled, let audioURL {
            do {
                try audioRecorder?.startRecording(to: audioURL)
                activeAudioURLs[id] = audioURL
            } catch {
                try? updatedStore.failRecording(session.id, message: userFacingMessage(error))
                store = updatedStore
                consentSheetVisible = false
                consentAccepted = false
                persist()
                return
            }
        }
        recordingClocks[id] = RecordingClock(baseElapsedSeconds: 0, startedAt: Date())
        try? updatedStore.startRecording(session.id, elapsedSeconds: 0)
        store = updatedStore
        consentSheetVisible = false
        consentAccepted = false
        currentTopicTitle = "Listening"
        persist()
    }

    func togglePause() {
        guard let session = selectedSession,
              let id = store.selectedSessionID else { return }
        let elapsedSeconds = elapsedSeconds(
            for: id,
            fallback: selectedSession?.status.elapsedSeconds ?? 0
        )
        if case .paused = session.status {
            if !fixtureRecordingEnabled {
                do {
                    try audioRecorder?.resumeRecording()
                } catch {
                    markFailed(id, error: error)
                    return
                }
            }
            recordingClocks[id] = RecordingClock(
                baseElapsedSeconds: elapsedSeconds,
                startedAt: Date()
            )
            var updatedStore = store
            try? updatedStore.startRecording(id, elapsedSeconds: elapsedSeconds)
            store = updatedStore
        } else {
            if !fixtureRecordingEnabled {
                audioRecorder?.pauseRecording()
            }
            recordingClocks[id] = RecordingClock(
                baseElapsedSeconds: elapsedSeconds,
                startedAt: nil
            )
            var updatedStore = store
            try? updatedStore.pauseRecording(id, elapsedSeconds: elapsedSeconds)
            store = updatedStore
        }
        persist()
    }

    func createNewTopic() {
        guard let session = selectedSession,
              let id = store.selectedSessionID else { return }
        let elapsedSeconds = elapsedSeconds(
            for: id,
            fallback: session.status.elapsedSeconds ?? session.transcript.last?.endTime ?? 0
        )
        var updatedStore = store
        if var activeTopic = session.topics.last, activeTopic.endTime == nil {
            activeTopic.endTime = elapsedSeconds
            try? updatedStore.upsertTopic(in: id, topic: activeTopic)
        }
        let nextTitle = "Topic \(session.topics.count + 1)"
        currentTopicTitle = nextTitle
        try? updatedStore.upsertTopic(
            in: id,
            topic: TopicNote(
                title: nextTitle,
                startTime: elapsedSeconds,
                endTime: nil,
                summary: "No summary yet.",
                keyPoints: [],
                questions: []
            )
        )
        store = updatedStore
        persist()
    }

    func canProcessRecoveredAudio(_ session: RecordingSession) -> Bool {
        recoveredProcessingUnavailableReason(session) == nil
    }

    func recoveredProcessingUnavailableReason(_ session: RecordingSession) -> String? {
        guard case .recovered = session.status else {
            return "Preserved audio is not available."
        }
        if store.sessions.contains(where: { $0.id != session.id && $0.status.blocksNewRecording }) {
            return "Finish the current recording before processing recovered audio."
        }
        guard let audioFileName = session.audioFileName,
              let audioURL = sessionFileStore?.localFileURL(relativePath: audioFileName) else {
            return "Preserved audio is not available."
        }
        if !FileManager.default.fileExists(atPath: audioURL.path) {
            return "Preserved audio is not available."
        }
        if inferenceRunner == nil {
            return "Local MLX runtime is not ready."
        }
        if (inferenceArtifactsRootURL ?? readyArtifactsURL()) == nil {
            return "Required local models are not ready."
        }
        return nil
    }

    func processRecoveredAudio(_ session: RecordingSession) {
        guard case let .recovered(durationSeconds) = session.status,
              let audioFileName = session.audioFileName,
              let audioURL = sessionFileStore?.localFileURL(relativePath: audioFileName),
              FileManager.default.fileExists(atPath: audioURL.path),
              let artifactsURL = inferenceArtifactsRootURL ?? readyArtifactsURL() else {
            return
        }
        finalizingDurations[session.id] = durationSeconds
        var updatedStore = store
        try? updatedStore.finalizeRecording(session.id, progress: 0.25)
        store = updatedStore
        persist()
        runInference(for: session.id, audioURL: audioURL, artifactsURL: artifactsURL)
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openModelInstallLocation() {
        let url = LocalModelBundleLocator().applicationSupportArtifactsURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func confirmStop() {
        stopConfirmationVisible = true
    }

    func stopAndFinalize() {
        guard let session = selectedSession,
              let id = store.selectedSessionID else { return }
        let durationSeconds = elapsedSeconds(
            for: id,
            fallback: session.status.elapsedSeconds
                ?? session.transcript.map(\.endTime).max()
                ?? session.topics.compactMap(\.endTime).max()
                ?? 0
        )
        finalizingDurations[id] = durationSeconds
        recordingClocks[id] = nil
        let audioURL: URL?
        if fixtureRecordingEnabled {
            audioURL = nil
        } else {
            do {
                let capturedDuration = try audioRecorder?.stopRecording() ?? durationSeconds
                finalizingDurations[id] = max(durationSeconds, capturedDuration)
                audioURL = activeAudioURLs[id] ?? session.audioFileName.map {
                    sessionFileStore?.localFileURL(relativePath: $0)
                } ?? nil
            } catch {
                markFailed(id, error: error)
                stopConfirmationVisible = false
                return
            }
        }
        var updatedStore = store
        try? updatedStore.finalizeRecording(id, progress: 0.25)
        store = updatedStore
        stopConfirmationVisible = false
        persist()
        if fixtureRecordingEnabled {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.completeFinalizing(id)
            }
        } else if let audioURL {
            runInference(for: id, audioURL: audioURL)
        }
    }

    func openSavedReview() {
        guard let session = selectedSession,
              let id = store.selectedSessionID else { return }
        let durationSeconds = finalizingDurations[id]
            ?? session.status.elapsedSeconds
            ?? session.transcript.last?.endTime
            ?? session.topics.compactMap(\.endTime).max()
            ?? 0
        var updatedStore = store
        try? updatedStore.saveRecording(
            id,
            durationSeconds: durationSeconds,
            audioFileName: session.audioFileName ?? audioFileName(for: id)
        )
        store = updatedStore
        persist()
    }

    func exportMarkdown(_ session: RecordingSession) {
        guard let sessionFileStore else {
            exportStatus = "Could not export Markdown."
            return
        }
        let exportURL = sessionFileStore.localFileURL(
            relativePath: "Exports/\(exportFileName(for: session.title))"
        )
        do {
            try FileManager.default.createDirectory(
                at: exportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try MarkdownExporter()
                .export(session)
                .write(to: exportURL, atomically: true, encoding: .utf8)
            exportStatus = "Exported Markdown"
        } catch {
            exportStatus = "Could not export Markdown."
        }
    }

    func completeFinalizing(_ id: UUID) {
        var updatedStore = store
        try? updatedStore.finalizeRecording(id, progress: 1.0)
        store = updatedStore
        persist()
    }

    private func runInference(for id: UUID, audioURL: URL) {
        let runner = inferenceRunner
        let artifactsURL = inferenceArtifactsRootURL ?? readyArtifactsURL()
        guard let runner, let artifactsURL else {
            markFailed(id, error: RecordingPipelineError.runtimeFailed("Local MLX runtime is not ready."))
            return
        }

        Task.detached { [runner, artifactsURL] in
            do {
                let output = try runner.process(audioURL: audioURL, artifactsRootURL: artifactsURL)
                await MainActor.run {
                    self.applyInferenceOutput(id: id, output: output)
                }
            } catch {
                await MainActor.run {
                    self.markFailed(id, error: error)
                }
            }
        }
    }

    private func retryRecoveredInferenceIfReady() {
        guard inferenceRunner != nil else { return }
        guard let artifactsURL = inferenceArtifactsRootURL ?? readyArtifactsURL() else { return }
        var updatedStore = store
        var retries: [(UUID, URL)] = []
        for session in store.sessions {
            guard case let .recovered(durationSeconds) = session.status,
                  session.transcript.isEmpty,
                  let audioFileName = session.audioFileName,
                  let audioURL = sessionFileStore?.localFileURL(relativePath: audioFileName),
                  FileManager.default.fileExists(atPath: audioURL.path) else {
                continue
            }
            finalizingDurations[session.id] = durationSeconds
            try? updatedStore.finalizeRecording(session.id, progress: 0.25)
            retries.append((session.id, audioURL))
        }
        guard !retries.isEmpty else { return }
        store = updatedStore
        persist()
        for retry in retries {
            runInference(for: retry.0, audioURL: retry.1, artifactsURL: artifactsURL)
        }
    }

    private func createRecoveredAudioFixtures() {
        guard let sessionFileStore else { return }
        for session in store.sessions {
            guard case .recovered = session.status,
                  let audioFileName = session.audioFileName else {
                continue
            }
            let audioURL = sessionFileStore.localFileURL(relativePath: audioFileName)
            try? FileManager.default.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: audioURL.path) {
                try? Data("audio\n".utf8).write(to: audioURL)
            }
        }
    }

    private func runInference(for id: UUID, audioURL: URL, artifactsURL: URL) {
        let runner = inferenceRunner
        guard let runner else {
            markFailed(id, error: RecordingPipelineError.runtimeFailed("Local MLX runtime is not ready."))
            return
        }

        Task.detached { [runner, artifactsURL] in
            do {
                let output = try runner.process(audioURL: audioURL, artifactsRootURL: artifactsURL)
                await MainActor.run {
                    self.applyInferenceOutput(id: id, output: output)
                }
            } catch {
                await MainActor.run {
                    self.markFailed(id, error: error)
                }
            }
        }
    }

    private func applyInferenceOutput(id: UUID, output: RecordingPipelineOutput) {
        var updatedStore = store
        let audioFileName = store.session(id: id)?.audioFileName ?? audioFileName(for: id)
        let durationSeconds = max(
            finalizingDurations[id] ?? 0,
            Int(output.metrics.audioDurationSeconds.rounded())
        )
        try? updatedStore.replaceGeneratedContent(
            in: id,
            transcript: output.transcript,
            topics: output.topics
        )
        try? updatedStore.saveRecording(
            id,
            durationSeconds: durationSeconds,
            audioFileName: audioFileName
        )
        store = updatedStore
        finalizingDurations[id] = nil
        recordingClocks[id] = nil
        activeAudioURLs[id] = nil
        persist()
    }

    private func markFailed(_ id: UUID, error: Error) {
        var updatedStore = store
        try? updatedStore.failRecording(id, message: userFacingMessage(error))
        store = updatedStore
        finalizingDurations[id] = nil
        recordingClocks[id] = nil
        activeAudioURLs[id] = nil
        persist()
    }

    private func readyArtifactsURL() -> URL? {
        if let inferenceArtifactsRootURL {
            return inferenceArtifactsRootURL
        }
        if let cachedReadyArtifactsRootURL {
            return cachedReadyArtifactsRootURL
        }
        let locator = LocalModelBundleLocator()
        let url = locator.firstReadyRoot(
            bundleResourceURL: Bundle.main.resourceURL,
            applicationSupportArtifactsURL: locator.applicationSupportArtifactsURL()
        )
        if let url {
            cachedReadyArtifactsRootURL = url
        }
        return url
    }

    private func persist() {
        do {
            try sessionFileStore?.save(store.sessions)
            if persistenceStatus == "Could not save library." {
                persistenceStatus = nil
            }
        } catch {
            persistenceStatus = "Could not save library."
        }
    }

    private func audioFileName(for id: UUID) -> String {
        "Audio/\(id.uuidString).m4a"
    }

    private func exportFileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let fileStem = title.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\((fileStem.isEmpty ? "Recording" : fileStem)).md"
    }

    private func elapsedSeconds(for id: UUID, fallback: Int) -> Int {
        guard let clock = recordingClocks[id] else {
            return fallback
        }
        guard let startedAt = clock.startedAt else {
            return clock.baseElapsedSeconds
        }
        return clock.baseElapsedSeconds + max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    private func resumeRecordingClocksForLoadedSessions() {
        let now = Date()
        for session in store.sessions {
            switch session.status {
            case let .recording(elapsedSeconds):
                recordingClocks[session.id] = RecordingClock(
                    baseElapsedSeconds: elapsedSeconds,
                    startedAt: now
                )
            case let .paused(elapsedSeconds):
                recordingClocks[session.id] = RecordingClock(
                    baseElapsedSeconds: elapsedSeconds,
                    startedAt: nil
                )
            default:
                continue
            }
        }
    }

    private func startLiveDurationUpdates() {
        liveDurationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.refreshRecordingDurations()
            }
        }
    }

    private func refreshRecordingDurations() {
        var updatedStore = store
        var changed = false
        for session in store.sessions {
            guard case let .recording(currentElapsedSeconds) = session.status else {
                continue
            }
            let nextElapsedSeconds = elapsedSeconds(
                for: session.id,
                fallback: currentElapsedSeconds
            )
            guard nextElapsedSeconds != currentElapsedSeconds else {
                continue
            }
            try? updatedStore.startRecording(
                session.id,
                elapsedSeconds: nextElapsedSeconds
            )
            changed = true
        }
        if changed {
            store = updatedStore
            persist()
        }
    }

    private static func sessionStoreURL(arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: "--session-store"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return defaultSessionStoreURL()
    }

    private static func defaultSessionStoreURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("LiveNotes", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private static func bundledModelReadiness() -> LocalModelBundleReadiness {
        let locator = LocalModelBundleLocator()
        return locator
            .resolveFirstReadyRoot(
                bundleResourceURL: Bundle.main.resourceURL,
                applicationSupportArtifactsURL: locator.applicationSupportArtifactsURL()
            )
    }

    private static func productionRecordingEngineStatus(
        helperURL: URL?,
        pythonExecutable: String
    ) -> String {
        guard helperURL != nil, pythonCanImportMLXRuntime(pythonExecutable) else {
            return "Local MLX runtime is not available."
        }
        return "Ready"
    }

    private static func productionPythonExecutable() -> String {
        if let override = ProcessInfo.processInfo.environment["LIVENOTES_PYTHON"], !override.isEmpty {
            return override
        }
        let runtimePython = defaultSessionStoreURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Runtime/bin/python3")
        if FileManager.default.fileExists(atPath: runtimePython.path) {
            return runtimePython.path
        }
        return "python3"
    }

    private static func recordingPipelineHelperURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["LIVENOTES_MLX_HELPER"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("livenotes_mlx_pipeline.py"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/livenotes_mlx_pipeline.py")
        return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
    }

    private static func pythonCanImportMLXRuntime(_ pythonExecutable: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            pythonExecutable,
            "-c",
            """
            import importlib.util
            missing = [
                name for name in ("mlx", "mlx_whisper", "mlx_lm")
                if importlib.util.find_spec(name) is None
            ]
            raise SystemExit(1 if missing else 0)
            """
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private func userFacingMessage(_ error: Error) -> String {
        if let pipelineError = error as? RecordingPipelineError,
           case .runtimeFailed = pipelineError {
            return "Local MLX inference failed."
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }

    private static func uiModelStatus(arguments: [String]) -> String {
        if argumentValue("--ui-model-status", in: arguments) == "missing" {
            return "Missing Files"
        }
        return "Ready"
    }

    private static func uiTestSessionFileStore(arguments: [String]) -> SessionFileStore? {
        guard let storePath = argumentValue("--session-store", in: arguments) else {
            return nil
        }
        return SessionFileStore(url: URL(fileURLWithPath: storePath))
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct RecordingClock {
    var baseElapsedSeconds: Int
    var startedAt: Date?
}

private extension RecordingStatus {
    var blocksNewRecording: Bool {
        switch self {
        case .preparing, .recording, .paused:
            return true
        case let .finalizing(progress):
            return progress < 1
        case .saved, .recovered, .failed:
            return false
        }
    }
}

private final class UITestAudioRecorder: AudioRecordingControlling {
    func startRecording(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    func pauseRecording() {}

    func resumeRecording() throws {}

    func stopRecording() throws -> Int {
        965
    }
}

private struct UITestInferenceRunner: RecordingInferenceRunning {
    func process(audioURL: URL, artifactsRootURL: URL) throws -> RecordingPipelineOutput {
        RecordingPipelineOutput(
            transcript: [
                TranscriptSentence(
                    startTime: 0,
                    endTime: 7,
                    text: "We should follow up with the customer before Friday.",
                    translation: "我们应该在周五之前跟进客户。",
                    confidence: .high
                )
            ],
            topics: [
                TopicNote(
                    title: "Customer Follow-up",
                    startTime: 0,
                    endTime: 965,
                    summary: "The session confirms a customer follow-up before Friday.",
                    keyPoints: ["Follow up with the customer before Friday."],
                    questions: []
                )
            ],
            metrics: RecordingPipelineMetrics(
                audioDurationSeconds: 965,
                transcriptSegments: 1,
                translationSegments: 1,
                topicCount: 1
            )
        )
    }
}

enum DemoData {
    static let decisionTopic = TopicNote(
        title: "Decision Point",
        startTime: 883,
        endTime: 1_289,
        summary: "The team identifies the decision, tradeoffs, and next steps.",
        keyPoints: [
            "The decision depends on customer impact.",
            "Risks are captured before the follow-up.",
            "Next steps stay attached to the topic."
        ],
        questions: [
            "What tradeoff needs a decision?"
        ]
    )

    static func homeStore() -> SessionStore {
        SessionStore(
            sessions: [
                liveSession(),
                savedSession(title: "Customer Call", duration: 1_860),
                savedSession(title: "Research Notes", duration: 2_820),
                RecordingSession(
                    title: "Design Review",
                    createdAt: Date(timeIntervalSince1970: 1_700),
                    status: .finalizing(progress: 0.62)
                ),
                RecordingSession(
                    title: "Recovered Audio",
                    createdAt: Date(timeIntervalSince1970: 1_600),
                    status: .recovered(durationSeconds: 2_280),
                    audioFileName: "Audio/recovered-audio.m4a"
                )
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func liveStore() -> SessionStore {
        SessionStore(
            sessions: [
                liveSession(),
                savedSession(title: "Customer Call", duration: 1_860),
                savedSession(title: "Research Notes", duration: 2_820)
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func pausedStore() -> SessionStore {
        var session = liveSession()
        session.status = .paused(elapsedSeconds: 908)
        return SessionStore(
            sessions: [
                session,
                savedSession(title: "Customer Call", duration: 1_860),
                savedSession(title: "Research Notes", duration: 2_820)
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func savedStore() -> SessionStore {
        let saved = savedSession(title: "Product Review", duration: 3_120)
        return SessionStore(
            sessions: [
                saved,
                savedSession(title: "Customer Call", duration: 1_860),
                savedSession(title: "Research Notes", duration: 2_820)
            ],
            selectedSessionID: saved.id
        )
    }

    static func preparingStore() -> SessionStore {
        let preparing = RecordingSession(
            title: "Preparing Recording",
            createdAt: Date(timeIntervalSince1970: 1_900),
            status: .preparing
        )
        return SessionStore(
            sessions: [
                preparing,
                savedSession(title: "Customer Call", duration: 1_860)
            ],
            selectedSessionID: preparing.id
        )
    }

    static func failedStore() -> SessionStore {
        let failed = RecordingSession(
            title: "Audio Device Error",
            createdAt: Date(timeIntervalSince1970: 1_950),
            status: .failed(message: "Microphone access was interrupted.")
        )
        return SessionStore(
            sessions: [
                failed,
                savedSession(title: "Customer Call", duration: 1_860)
            ],
            selectedSessionID: failed.id
        )
    }

    static func finalizingCompleteStore() -> SessionStore {
        var finalizing = savedSession(title: "Product Review", duration: 3_120)
        finalizing.status = .finalizing(progress: 1.0)
        return SessionStore(
            sessions: [
                finalizing,
                savedSession(title: "Customer Call", duration: 1_860)
            ],
            selectedSessionID: finalizing.id
        )
    }

    static func recoveredStore() -> SessionStore {
        let recovered = RecordingSession(
            title: "Recovered Audio",
            createdAt: Date(timeIntervalSince1970: 1_600),
            status: .recovered(durationSeconds: 2_280),
            audioFileName: "Audio/recovered-audio.m4a"
        )
        return SessionStore(
            sessions: [
                recovered,
                savedSession(title: "Customer Call", duration: 1_860)
            ],
            selectedSessionID: recovered.id
        )
    }

    static func emptyStore() -> SessionStore {
        SessionStore(sessions: [], selectedSessionID: nil)
    }

    private static let liveSessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private static func liveSession() -> RecordingSession {
        RecordingSession(
            id: liveSessionID,
            title: "Product Review",
            createdAt: Date(timeIntervalSince1970: 1_800),
            status: .recording(elapsedSeconds: 908),
            audioFileName: "Audio/neural-networks-live.m4a",
            transcript: [
                TranscriptSentence(
                    startTime: 842,
                    endTime: 851,
                    text: "We start with the customer problem.",
                    translation: DemoTranslation.customerProblem,
                    confidence: .high
                ),
                TranscriptSentence(
                    startTime: 883,
                    endTime: 895,
                    text: "The main tradeoff is speed versus accuracy.",
                    translation: DemoTranslation.tradeoff,
                    confidence: .low
                )
            ],
            topics: [decisionTopic]
        )
    }

    private static func savedSession(title: String, duration: Int) -> RecordingSession {
        RecordingSession(
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_500),
            status: .saved(durationSeconds: duration),
            audioFileName: "Audio/\(title.lowercased().replacingOccurrences(of: " ", with: "-")).m4a",
            transcript: [
                TranscriptSentence(
                    startTime: 883,
                    endTime: 895,
                    text: "The main tradeoff is speed versus accuracy.",
                    translation: DemoTranslation.tradeoff,
                    confidence: .high
                )
            ],
            topics: [
                TopicNote(
                    title: "Opening Context",
                    startTime: 0,
                    endTime: 491,
                    summary: "The session starts by identifying the customer problem.",
                    keyPoints: ["Customer impact sets the priority."],
                    questions: []
                ),
                TopicNote(
                    title: "Tradeoff Review",
                    startTime: 492,
                    endTime: 882,
                    summary: "The team compares speed, accuracy, and follow-up cost.",
                    keyPoints: ["The fastest path still needs quality checks."],
                    questions: []
                ),
                decisionTopic,
                TopicNote(
                    title: "Next Steps",
                    startTime: 1_290,
                    endTime: 2_046,
                    summary: "Owners and next steps are captured before the session ends.",
                    keyPoints: ["Each owner has one follow-up item."],
                    questions: []
                )
            ]
        )
    }
}

enum DemoTranslation {
    static let customerProblem = text([
        0x6211, 0x4EEC, 0x5148, 0x786E, 0x8BA4, 0x5BA2, 0x6237,
        0x95EE, 0x9898, 0x3002
    ])

    static let tradeoff = text([
        0x4E3B, 0x8981, 0x53D6, 0x820D, 0x662F, 0x901F, 0x5EA6,
        0x548C, 0x51C6, 0x786E, 0x6027, 0x3002
    ])

    private static func text(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init)))
    }
}
