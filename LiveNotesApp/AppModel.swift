import Foundation
import AppKit
@preconcurrency import AVFoundation
import SwiftUI
@preconcurrency import UniformTypeIdentifiers
#if canImport(Translation)
@preconcurrency import Translation
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var store: SessionStore
    @Published var newRecordingSheetVisible = false
    @Published var consentSheetVisible = false
    @Published var stopConfirmationVisible = false
    @Published var consentAccepted = false
    @Published var recordingName = "Recording"
    @Published var recordingEngineStatus: String
    @Published var persistenceStatus: String?
    @Published var exportStatus: SessionExportStatus?
    @Published var partialExportConfirmationVisible = false
    @Published var translationRequestVersion = 0
    @Published var liveTranscriptPreview = ""
    @Published var liveTranslationPreview = ""
    @Published var liveAudioLevel = 0.0
    @Published var recordingPreparationTitle: String?
    @Published var recordingPreparationNeedsHelp = false
    @Published var recordingStartFailure: RecordingStartFailure?

    private let sessionFileStore: SessionFileStore?
    private let fixtureRecordingEnabled: Bool
    private var audioRecorder: AudioRecordingControlling?
    private var inferenceRunner: (any RecordingInferenceRunning)?
    private var liveTranscriber: LiveTranscriptionRunning?
    private var recordingPreflight: (@MainActor @Sendable () async throws -> Void)?
    private var inferenceArtifactsRootURL: URL?
    private let audioStartTimeoutSeconds: TimeInterval
    private var finalizingDurations: [UUID: Int] = [:]
    private var recordingClocks: [UUID: RecordingClock] = [:]
    private var activeAudioURLs: [UUID: URL] = [:]
    private var liveTranscriptionSessionID: UUID?
    private var pendingTranslationJobs: [TranslationJob] = []
    private var pendingTranslationKeys = Set<String>()
    private var translationAttemptCounts: [String: Int] = [:]
    private var cancelledTranslationGenerationKeys = Set<String>()
    private var pendingFinalSaves: [UUID: PendingFinalSave] = [:]
    private var finalSaveTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptGenerations: [UUID: Int] = [:]
    private var lastQueuedPreviewTranslation = ""
    private var recordingPreparationID: UUID?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingPreparationHelpTask: Task<Void, Never>?
    private var liveDurationTask: Task<Void, Never>?
    private var translationRetryTask: Task<Void, Never>?
    private var liveTranscriptionStartTask: Task<Void, Never>?
    private var partialExportSessionID: UUID?
    private var exportDirectoryOverrideURL: URL?
    private let exportDirectoryHistory = ExportDirectoryHistory()
    private var translationTaskRunning = false
    private var translationTaskScheduled = false
#if canImport(Translation)
    private var activeTranslationSession: TranslationSession?
#endif
    private var uiTestTranslationProvider: (@MainActor @Sendable (String) -> String?)?
    private var uiTestTranslationDelayNanoseconds: UInt64 = 1_000_000_000
    private var uiTestTranslationHangs = false
    private let finalSaveTranslationTimeoutSeconds: TimeInterval

    init(
        store: SessionStore,
        sessionFileStore: SessionFileStore? = nil,
        recordingEngineStatus: String = "Ready",
        fixtureRecordingEnabled: Bool = false,
        audioRecorder: AudioRecordingControlling? = nil,
        inferenceRunner: (any RecordingInferenceRunning)? = nil,
        liveTranscriber: LiveTranscriptionRunning? = nil,
        recordingPreflight: (@MainActor @Sendable () async throws -> Void)? = nil,
        inferenceArtifactsRootURL: URL? = nil,
        audioStartTimeoutSeconds: TimeInterval = 8,
        finalSaveTranslationTimeoutSeconds: TimeInterval = 18
    ) {
        self.store = store
        self.sessionFileStore = sessionFileStore
        self.recordingEngineStatus = recordingEngineStatus
        self.fixtureRecordingEnabled = fixtureRecordingEnabled
        self.audioRecorder = audioRecorder
        self.inferenceRunner = inferenceRunner
        self.liveTranscriber = liveTranscriber
        self.recordingPreflight = recordingPreflight
        self.inferenceArtifactsRootURL = inferenceArtifactsRootURL
        self.audioStartTimeoutSeconds = audioStartTimeoutSeconds
        self.finalSaveTranslationTimeoutSeconds = finalSaveTranslationTimeoutSeconds
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
        let model = AppModel(
            store: store,
            sessionFileStore: fileStore,
            recordingEngineStatus: "Ready",
            audioRecorder: nil,
            inferenceRunner: nil,
            liveTranscriber: nil,
            recordingPreflight: nil,
            inferenceArtifactsRootURL: nil
        )
        model.configureProductionRuntime()
        model.configureExportDirectoryOverride(arguments: arguments)
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
        let store: SessionStore
        switch argumentValue("--ui-state", in: arguments) {
        case "saved":
            store = DemoData.savedStore()
        case "live":
            store = DemoData.liveStore()
        case "long-live":
            store = DemoData.longLiveStore()
        case "live-preview-only":
            store = DemoData.livePreviewOnlyStore()
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
        let recordingRuntime = argumentValue("--ui-recording-runtime", in: arguments)
        let audioFileUsesNativeInference = recordingRuntime == "audio-file"
            && argumentValue("--ui-native-inference", in: arguments) == "true"
        let audioFileModelBox = WeakAppModelBox()
        var audioFileTranscriber: NativeSpeechLiveTranscriber?
        let audioRecorder: AudioRecordingControlling? = switch recordingRuntime {
        case "simulated":
            UITestAudioRecorder()
        case "observable":
            UITestAudioRecorder()
        case "hanging-audio":
            HangingUITestAudioRecorder()
        case "audio-file":
            {
                let transcriber = audioFileUsesNativeInference ? NativeSpeechLiveTranscriber() : nil
                audioFileTranscriber = transcriber
                let fixturePath = argumentValue("--ui-audio-fixture", in: arguments)
                    ?? "/tmp/livenotes-e2e-audio-fixture.m4a"
                let fixtureURL = URL(fileURLWithPath: fixturePath)
                return AVAudioRecordingEngine(
                    microphonePermissionAuthorizer: .preflightGranted,
                    liveAudioHandler: { buffer in
                        transcriber?.append(buffer)
                        let level = AudioLevelMeter.normalizedLevel(for: buffer)
                        Task { @MainActor in
                            audioFileModelBox.model?.updateLiveAudioLevel(level)
                        }
                    },
                    audioInputProviderFactory: {
                        UITestAudioFileInputProvider(audioURL: fixtureURL)
                    }
                )
            }()
        default:
            nil
        }
        let simulatedRuntime = audioRecorder != nil
        let usesNativeInference = audioFileUsesNativeInference
        let inferenceOutput = argumentValue("--ui-inference-output", in: arguments) ?? "success"
        let audioStartTimeoutSeconds = argumentValue("--ui-audio-start-timeout", in: arguments).flatMap(Double.init) ?? 8
        let finalSaveTranslationTimeoutSeconds = argumentValue(
            "--ui-final-save-translation-timeout",
            in: arguments
        ).flatMap(Double.init) ?? 18
        let liveTranscriber = argumentValue("--ui-live-transcriber", in: arguments) == "hanging"
            ? HangingUITestLiveTranscriber()
            : nil
        let recordingPreflight: (@MainActor @Sendable () async throws -> Void)?
        switch argumentValue("--ui-recording-preflight", in: arguments) {
        case "hanging":
            recordingPreflight = { @MainActor @Sendable in
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        case "delayed-success":
            recordingPreflight = { @MainActor @Sendable in
                try await Task.sleep(nanoseconds: 2_500_000_000)
            }
        case "speech-denied":
            recordingPreflight = { @MainActor @Sendable in
                throw RecordingPipelineError.speechRecognitionAccessDenied
            }
        default:
            recordingPreflight = nil
        }
        try? fileStore?.save(store.sessions)
        let model = AppModel(
            store: store,
            sessionFileStore: fileStore,
            fixtureRecordingEnabled: !simulatedRuntime,
            audioRecorder: audioRecorder,
            inferenceRunner: usesNativeInference
                ? NativeSpeechInferenceRunner()
                : (simulatedRuntime ? UITestInferenceRunner(output: inferenceOutput) : nil),
            liveTranscriber: liveTranscriber ?? audioFileTranscriber,
            recordingPreflight: recordingPreflight,
            inferenceArtifactsRootURL: simulatedRuntime ? FileManager.default.temporaryDirectory : nil,
            audioStartTimeoutSeconds: audioStartTimeoutSeconds,
            finalSaveTranslationTimeoutSeconds: finalSaveTranslationTimeoutSeconds
        )
        audioFileModelBox.model = model
        if let fileStore {
            model.exportDirectoryOverrideURL = fileStore.libraryDirectoryURL
                .appendingPathComponent("Exports", isDirectory: true)
        }
        model.configureExportDirectoryOverride(arguments: arguments)
        if simulatedRuntime && !usesNativeInference {
            model.createUITestAudioFixtures()
        }
        switch argumentValue("--ui-translation-mode", in: arguments) {
        case "instant":
            model.uiTestTranslationDelayNanoseconds = 1_000_000_000
            model.uiTestTranslationProvider = { text in
                UITestTranslationProvider.translation(for: text)
            }
        case "delayed":
            model.uiTestTranslationDelayNanoseconds = 3_000_000_000
            model.uiTestTranslationProvider = { text in
                UITestTranslationProvider.translation(for: text)
            }
        case "unavailable":
            model.uiTestTranslationDelayNanoseconds = 250_000_000
            model.uiTestTranslationProvider = { _ in
                nil
            }
        case "empty":
            model.uiTestTranslationDelayNanoseconds = 250_000_000
            model.uiTestTranslationProvider = { _ in
                ""
            }
        case "hanging":
            model.uiTestTranslationHangs = true
            model.uiTestTranslationProvider = { text in
                UITestTranslationProvider.translation(for: text)
            }
        default:
            break
        }
        if simulatedRuntime, argumentValue("--ui-retry-recovered", in: arguments) == "true" {
            model.retryRecoveredInferenceIfReady()
        }
        if let persistenceStatus = argumentValue("--ui-persistence-status", in: arguments) {
            model.persistenceStatus = persistenceStatus
        }
        if ["live", "long-live", "live-preview-only"].contains(argumentValue("--ui-state", in: arguments)) {
            model.liveTranscriptPreview = DemoText.livePreview
            model.liveTranslationPreview = DemoTranslation.livePreview
            model.liveAudioLevel = 0.58
        }
        return model
    }

    private func configureProductionRuntime() {
        let transcriber = NativeSpeechLiveTranscriber()
        let modelBox = WeakAppModelBox()
        modelBox.model = self
        liveTranscriber = transcriber
        audioRecorder = AVAudioRecordingEngine(
            microphonePermissionAuthorizer: .preflightGranted,
            liveAudioHandler: { buffer in
                transcriber.append(buffer)
                let level = AudioLevelMeter.normalizedLevel(for: buffer)
                Task { @MainActor in
                    modelBox.model?.updateLiveAudioLevel(level)
                }
            }
        )
        recordingPreflight = { @MainActor @Sendable in
            try await MicrophonePermissionAuthorizer.live.authorize()
            try await SpeechRecognitionPermissionAuthorizer.live.authorize()
            try await AppModel.ensureEnglishChineseTranslationReady()
        }
        inferenceRunner = NativeSpeechInferenceRunner()
        inferenceArtifactsRootURL = FileManager.default.temporaryDirectory
    }

    private func configureExportDirectoryOverride(arguments: [String]) {
        guard let path = Self.argumentValue("--export-directory", in: arguments) else {
            return
        }
        exportDirectoryOverrideURL = URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func ensureEnglishChineseTranslationReady() async throws {
#if canImport(Translation)
        if #available(macOS 26.4, *) {
            let availability = LanguageAvailability(preferredStrategy: .lowLatency)
            let status = await availability.status(
                from: Locale.Language(identifier: "en"),
                to: Locale.Language(identifier: "zh-Hans")
            )
            switch status {
            case .installed:
                return
            case .supported:
                throw RecordingPipelineError.runtimeFailed(
                    "English to Chinese translation is not installed. Download English and Chinese in the Translate app before recording."
                )
            case .unsupported:
                throw RecordingPipelineError.runtimeFailed(
                    "English to Chinese translation is not available on this Mac."
                )
            @unknown default:
                throw RecordingPipelineError.runtimeFailed(
                    "English to Chinese translation is not ready."
                )
            }
        }
#endif
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

    var selectedLiveSpeechPreview: LiveSpeechPreview? {
        guard let session = selectedSession,
              session.status.acceptsLiveTranscript,
              !liveTranscriptPreview.isEmpty else {
            return nil
        }
        return LiveSpeechPreview(
            text: liveTranscriptPreview,
            translation: liveTranslationPreview
        )
    }

    var canRequestRecording: Bool {
        activeRecordingReason == nil && recordingUnavailableReason == nil
    }

    var canShowNewRecording: Bool {
        activeRecordingReason == nil && recordingUnavailableReason == nil
    }

    var shouldShowSidebarNewRecording: Bool {
        !store.sessions.isEmpty || recordingPreparationTitle != nil
    }

    var sidebarNewRecordingHelp: String? {
        if let activeRecordingReason {
            return activeRecordingReason
        }
        if recordingUnavailableReason == "Local processing is unavailable." {
            return nil
        }
        return recordingUnavailableReason
    }

    var newRecordingUnavailableReason: String? {
        activeRecordingReason ?? recordingUnavailableReason
    }

    var recordingUnavailableReason: String? {
        if recordingEngineStatus != "Ready" {
            return recordingEngineStatus
        }
        if persistenceStatus == "Could not save library." {
            return persistenceStatus
        }
        return nil
    }

    private var activeRecordingReason: String? {
        if recordingPreparationTitle != nil {
            return "Finish or cancel setup first."
        }
        if store.sessions.contains(where: { $0.status.isPreparing }) {
            return "Finish or cancel setup first."
        }
        return store.sessions.contains { $0.status.blocksNewRecording }
            ? "Recording in progress."
            : nil
    }

    func canSelect(_ session: RecordingSession) -> Bool {
        guard let activeSessionID = store.sessions.first(where: { $0.status.blocksNewRecording })?.id else {
            return true
        }
        return session.id == activeSessionID
    }

    func select(_ session: RecordingSession) {
        guard canSelect(session) else { return }
        recordingStartFailure = nil
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

    func deferRecoveredAudio(_ session: RecordingSession) {
        guard let nextSession = store.sessions.first(where: { $0.id != session.id && canSelect($0) }) else {
            return
        }
        select(nextSession)
    }

    func showNewRecording() {
        guard canShowNewRecording else { return }
        recordingStartFailure = nil
        recordingName = defaultRecordingName()
        consentAccepted = false
        consentSheetVisible = true
    }

    func continueAfterRecordingConsent() {
        guard consentAccepted, canRequestRecording else { return }
        consentSheetVisible = false
        Task { @MainActor [weak self] in
            self?.newRecordingSheetVisible = true
        }
    }

    func cancelRecordingConsent() {
        consentSheetVisible = false
        consentAccepted = false
    }

    func startRecording() {
        guard canRequestRecording else { return }
        clearTransientStatusForNewRecording()
        let title = recordingName.isEmpty ? defaultRecordingName() : recordingName
        let id = UUID()
        let audioFileName = audioFileName(for: id)
        let audioURL = sessionFileStore?.localFileURL(relativePath: audioFileName)
        newRecordingSheetVisible = false
        consentSheetVisible = false
        consentAccepted = false
        recordingStartFailure = nil
        if !fixtureRecordingEnabled, audioURL != nil {
            recordingStartTask?.cancel()
            recordingPreparationID = id
            recordingPreparationTitle = title
            scheduleRecordingPreparationHelp(for: id)
            recordingStartTask = Task { @MainActor [weak self] in
                await self?.startNativeRecording(
                    title: title,
                    id: id,
                    audioFileName: audioFileName,
                    audioURL: audioURL
                )
            }
            return
        }
        var updatedStore = store
        let session = updatedStore.createRecording(
            id: id,
            named: title,
            audioFileName: audioFileName
        )
        store = updatedStore
        transcriptGenerations[id] = 0
        persist()
        activateRecording(id: session.id, audioURL: audioURL)
    }

    func cancelRecordingPreparation() {
        guard recordingPreparationTitle != nil || selectedSession?.status.isPreparing == true else { return }
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingPreparationID = nil
        recordingPreparationTitle = nil
        cancelRecordingPreparationHelp()
        recordingStartFailure = nil
        newRecordingSheetVisible = false
        consentSheetVisible = false
        consentAccepted = false
        if let session = selectedSession, session.status.isPreparing {
            var updatedStore = store
            try? updatedStore.removeSession(session.id)
            store = updatedStore
            persist()
        }
    }

    func retryRecordingStartFailure() {
        guard let failure = recordingStartFailure, canRequestRecording else { return }
        recordingName = failure.title
        startRecording()
    }

    private func startNativeRecording(
        title: String,
        id: UUID,
        audioFileName: String,
        audioURL: URL?
    ) async {
        guard let audioURL else {
            if recordingPreparationID == id {
                recordStartFailure(
                    title: title,
                    error: RecordingPipelineError.runtimeFailed("Could not save library.")
                )
            }
            return
        }
        do {
            try await runRecordingPreflight()
            guard recordingPreparationID == id, !Task.isCancelled else {
                return
            }
            var updatedStore = store
            let session = updatedStore.createRecording(
                id: id,
                named: title,
                audioFileName: audioFileName
            )
            store = updatedStore
            transcriptGenerations[id] = 0
            persist()

            startLiveTranscription(for: session.id)
            guard recordingPreparationID == id, !Task.isCancelled else {
                liveTranscriber?.cancel()
                removePreparingSession(id)
                return
            }

            try await startAudioRecorder(to: audioURL)
            guard recordingPreparationID == id, !Task.isCancelled else {
                _ = try? audioRecorder?.stopRecording()
                liveTranscriber?.cancel()
                removePreparingSession(id)
                return
            }
            recordingPreparationID = nil
            recordingStartTask = nil
            recordingPreparationTitle = nil
            cancelRecordingPreparationHelp()
            activateRecording(id: session.id, audioURL: audioURL)
        } catch {
            liveTranscriptionStartTask?.cancel()
            liveTranscriptionStartTask = nil
            liveTranscriber?.cancel()
            removePreparingSession(id)
            guard recordingPreparationID == id, !Task.isCancelled else { return }
            recordStartFailure(title: title, error: error)
        }
    }

    private func runRecordingPreflight() async throws {
        guard let recordingPreflight else { return }
        try await recordingPreflight()
    }

    private func scheduleRecordingPreparationHelp(for id: UUID) {
        recordingPreparationHelpTask?.cancel()
        recordingPreparationNeedsHelp = false
        recordingPreparationHelpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self,
                  self.recordingPreparationID == id,
                  self.recordingPreparationTitle != nil else {
                return
            }
            self.recordingPreparationNeedsHelp = true
        }
    }

    private func cancelRecordingPreparationHelp() {
        recordingPreparationHelpTask?.cancel()
        recordingPreparationHelpTask = nil
        recordingPreparationNeedsHelp = false
    }

    private func startAudioRecorder(to audioURL: URL) async throws {
        guard let audioRecorder else { return }
        let timeoutNanoseconds = UInt64(max(0.1, audioStartTimeoutSeconds) * 1_000_000_000)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let box = AudioStartContinuation(continuation)
            Task.detached(priority: .userInitiated) {
                do {
                    try await audioRecorder.startRecording(to: audioURL)
                    if !box.resume(with: .success(())) {
                        _ = try? audioRecorder.stopRecording()
                    }
                } catch {
                    _ = box.resume(with: .failure(error))
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let error = RecordingPipelineError.runtimeFailed(
                    "LiveNotes could not access the microphone. Check microphone permission or audio input, then try again."
                )
                _ = box.resume(with: .failure(error))
            }
        }
    }

    private func removePreparingSession(_ id: UUID) {
        guard store.session(id: id)?.status.isPreparing == true else { return }
        var updatedStore = store
        try? updatedStore.removeSession(id)
        store = updatedStore
        persist()
    }

    private func startLiveTranscription(for sessionID: UUID) {
        guard let liveTranscriber else { return }
        liveTranscriptionStartTask?.cancel()
        liveTranscriptionStartTask = nil
        let modelBox = WeakAppModelBox()
        modelBox.model = self
        liveTranscriptionSessionID = sessionID
        liveTranscriptionStartTask = Task(priority: .userInitiated) { [liveTranscriber] in
            do {
                try await liveTranscriber.start { event in
                    Task { @MainActor in
                        modelBox.model?.handleLiveTranscriptionEvent(event)
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    modelBox.model?.handleLiveTranscriptionStartFailure(sessionID: sessionID, error: error)
                }
            }
        }
    }

    private func handleLiveTranscriptionStartFailure(sessionID: UUID, error: Error) {
        guard liveTranscriptionSessionID == sessionID else { return }
        persistenceStatus = userFacingMessage(error)
    }

    private func activateRecording(id: UUID, audioURL: URL?) {
        if let audioURL {
            activeAudioURLs[id] = audioURL
        }
        liveTranscriptionSessionID = id
        resetLivePreview()
        liveAudioLevel = 0
        recordingClocks[id] = RecordingClock(baseElapsedSeconds: 0, startedAt: Date())
        var updatedStore = store
        try? updatedStore.startRecording(id, elapsedSeconds: 0)
        store = updatedStore
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
                    liveTranscriber?.resume()
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
            liveAudioLevel = 0
            if !fixtureRecordingEnabled {
                audioRecorder?.pauseRecording()
                liveTranscriber?.pause()
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

    func canProcessRecoveredAudio(_ session: RecordingSession) -> Bool {
        recoveredProcessingUnavailableReason(session) == nil
    }

    func recoveredProcessingUnavailableReason(_ session: RecordingSession) -> String? {
        guard case .recovered = session.status else {
            return "Saved audio is not available."
        }
        if store.sessions.contains(where: { $0.id != session.id && $0.status.blocksNewRecording }) {
            return "Finish the active recording before recovering this one."
        }
        guard let audioFileName = session.audioFileName,
              let audioURL = sessionFileStore?.localFileURL(relativePath: audioFileName) else {
            return "Saved audio is not available."
        }
        if !FileManager.default.fileExists(atPath: audioURL.path) {
            return "Saved audio is not available."
        }
        if inferenceRunner == nil {
            return "Local processing is unavailable."
        }
        return nil
    }

    func processRecoveredAudio(_ session: RecordingSession) {
        guard case let .recovered(durationSeconds) = session.status,
              let audioFileName = session.audioFileName,
              let audioURL = sessionFileStore?.localFileURL(relativePath: audioFileName),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            return
        }
        finalizingDurations[session.id] = durationSeconds
        var updatedStore = store
        try? updatedStore.finalizeRecording(session.id, progress: 0.25)
        store = updatedStore
        persist()
        runInference(for: session.id, audioURL: audioURL)
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openSpeechRecognitionSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func confirmStop() {
        stopConfirmationVisible = true
    }

    func stopAndFinalize() {
        Task { @MainActor [weak self] in
            await self?.stopAndFinalizeRecording()
        }
    }

    private func stopAndFinalizeRecording() async {
        guard let session = selectedSession,
              let id = store.selectedSessionID else { return }
        let durationSeconds = elapsedSeconds(
            for: id,
            fallback: session.status.elapsedSeconds
                ?? session.transcript.map(\.endTime).max()
                ?? 0
        )
        finalizingDurations[id] = durationSeconds
        recordingClocks[id] = nil
        let audioURL: URL?
        var flushedTranscript: [TranscriptSentence] = []
        if fixtureRecordingEnabled {
            audioURL = nil
        } else {
            do {
                let capturedDuration = try audioRecorder?.stopRecording() ?? durationSeconds
                liveTranscriptionStartTask?.cancel()
                liveTranscriptionStartTask = nil
                flushedTranscript = await liveTranscriber?.finish() ?? []
                finalizingDurations[id] = max(durationSeconds, capturedDuration)
                audioURL = activeAudioURLs[id] ?? session.audioFileName.map {
                    sessionFileStore?.localFileURL(relativePath: $0)
                } ?? nil
            } catch {
                liveTranscriber?.cancel()
                markFailed(id, error: error)
                stopConfirmationVisible = false
                return
            }
        }
        if !flushedTranscript.isEmpty {
            var transcriptStore = store
            for sentence in sanitizedTranscript(
                flushedTranscript,
                maximumEndTime: finalizingDurations[id] ?? durationSeconds
            ) {
                try? transcriptStore.upsertTranscript(in: id, sentence: sentence)
            }
            store = transcriptStore
        }
        if liveTranscriptionSessionID == id {
            liveTranscriptionSessionID = nil
        }
        liveAudioLevel = 0
        resetLivePreview()
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
            runInference(
                for: id,
                audioURL: audioURL
            )
        }
    }

    func openSavedReview() {
        guard let session = selectedSession,
              let id = store.selectedSessionID else { return }
        let durationSeconds = finalizingDurations[id]
            ?? session.status.elapsedSeconds
            ?? session.transcript.last?.endTime
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
        if session.hasMissingTranslations {
            partialExportSessionID = session.id
            partialExportConfirmationVisible = true
            setExportStatus(
                "Translation is incomplete. Retry translation or export anyway.",
                for: session.id,
                kind: .warning
            )
            return
        }
        writeMarkdown(session, incomplete: false)
    }

    func confirmPartialExport() {
        guard let sessionID = partialExportSessionID,
              let session = store.session(id: sessionID) else {
            partialExportConfirmationVisible = false
            partialExportSessionID = nil
            return
        }
        partialExportConfirmationVisible = false
        partialExportSessionID = nil
        writeMarkdown(session, incomplete: true)
    }

    func retryPartialExportTranslation() {
        guard let sessionID = partialExportSessionID,
              let session = store.session(id: sessionID) else {
            partialExportConfirmationVisible = false
            partialExportSessionID = nil
            return
        }
        partialExportConfirmationVisible = false
        partialExportSessionID = nil
        retryMissingTranslations(in: session)
    }

    func cancelPartialExport() {
        partialExportConfirmationVisible = false
        partialExportSessionID = nil
    }

    func exportStatus(for session: RecordingSession) -> SessionExportStatus? {
        guard exportStatus?.sessionID == session.id else {
            return nil
        }
        return exportStatus
    }

    private func writeMarkdown(_ session: RecordingSession, incomplete: Bool) {
        guard let sessionFileStore else {
            setExportStatus("Could not export Markdown.", for: session.id, kind: .failure)
            return
        }
        guard let exportURL = markdownExportURL(for: session, defaultDirectory: sessionFileStore.localFileURL(relativePath: "Exports")) else {
            setExportStatus("Export canceled.", for: session.id, kind: .warning)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: exportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try MarkdownExporter()
                .export(session)
                .write(to: exportURL, atomically: true, encoding: .utf8)
            exportDirectoryHistory.rememberExportURL(exportURL)
            NSWorkspace.shared.activateFileViewerSelecting([exportURL])
            setExportStatus(
                incomplete
                    ? "Incomplete export saved to \(exportURL.path)"
                    : "Saved to \(exportURL.path)",
                for: session.id,
                kind: incomplete ? .warning : .success
            )
        } catch {
            setExportStatus("Could not export Markdown.", for: session.id, kind: .failure)
        }
    }

    private func markdownExportURL(for session: RecordingSession, defaultDirectory: URL) -> URL? {
        if let exportDirectoryOverrideURL {
            return exportDirectoryOverrideURL.appendingPathComponent(exportFileName(for: session.title))
        }
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = exportFileName(for: session.title)
        panel.directoryURL = exportDirectoryHistory.directory(defaultDirectory: defaultDirectory)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func retryMissingTranslations(in session: RecordingSession) {
        let missingSentences = session.transcript.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !missingSentences.isEmpty else {
            setExportStatus("Translations are complete.", for: session.id, kind: .success)
            return
        }
        clearCancelledTranslationGenerations(for: session.id)
        for sentence in missingSentences {
            queueTranslation(for: sentence, in: session.id)
        }
        setExportStatus("Retrying translation.", for: session.id, kind: .progress)
    }

    private func setExportStatus(
        _ message: String,
        for sessionID: UUID,
        kind: SessionExportStatusKind
    ) {
        exportStatus = SessionExportStatus(
            sessionID: sessionID,
            message: message,
            kind: kind
        )
    }

    func completeFinalizing(_ id: UUID) {
        let session = store.session(id: id)
        let durationSeconds = finalizingDurations[id]
            ?? session?.status.elapsedSeconds
            ?? session?.transcript.last?.endTime
            ?? 0
        var updatedStore = store
        try? updatedStore.saveRecording(
            id,
            durationSeconds: durationSeconds,
            audioFileName: session?.audioFileName ?? audioFileName(for: id)
        )
        store = updatedStore
        pendingFinalSaves[id] = nil
        cancelFinalSaveTimeout(for: id)
        finalizingDurations[id] = nil
        persist()
    }

    private func runInference(
        for id: UUID,
        audioURL: URL
    ) {
        let runner = inferenceRunner
        let artifactsURL = inferenceArtifactsRootURL ?? FileManager.default.temporaryDirectory
        guard let runner else {
            markFailed(id, error: RecordingPipelineError.runtimeFailed("Local processing is unavailable."))
            return
        }

        Task.detached { [runner, artifactsURL] in
            do {
                let output = try runner.process(audioURL: audioURL, artifactsRootURL: artifactsURL)
                await MainActor.run {
                    self.applyInferenceOutput(
                        id: id,
                        output: output
                    )
                }
            } catch {
                await MainActor.run {
                    self.applyInferenceFailure(
                        id: id,
                        error: error
                    )
                }
            }
        }
    }

    private func handleLiveTranscriptionEvent(_ event: LiveTranscriptionEvent) {
        guard let id = liveTranscriptionSessionID,
              let session = store.session(id: id),
              session.status.acceptsLiveTranscript else {
            return
        }
        switch event {
        case .ready, .partialTranscript:
            clearLiveSpeechFailureStatus()
            if case let .partialTranscript(text) = event {
                updateLivePreview(text)
            }
        case let .committedTranscript(sentence):
            clearLiveSpeechFailureStatus()
            guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            var updatedStore = store
            try? updatedStore.upsertTranscript(in: id, sentence: sentence)
            store = updatedStore
            persist()
            queueTranslation(for: sentence, in: id)
        case let .failed(message):
            persistenceStatus = message
        }
    }

    private func clearTransientStatusForNewRecording() {
        if persistenceStatus != "Could not save library." {
            persistenceStatus = nil
        }
        exportStatus = nil
    }

    private func clearLiveSpeechFailureStatus() {
        if persistenceStatus == "Live speech recognition failed." {
            persistenceStatus = nil
        }
    }

    private func queueTranslation(for sentence: TranscriptSentence, in sessionID: UUID) {
        guard sentence.translation.isEmpty else { return }
        let generation = transcriptGenerations[sessionID, default: 0]
        guard !isTranslationGenerationCancelled(sessionID: sessionID, generation: generation) else {
            return
        }
        let key = TranslationJob.transcriptKey(
            sessionID: sessionID,
            generation: generation,
            sentence: sentence
        )
        guard !pendingTranslationKeys.contains(key) else { return }
        pendingTranslationKeys.insert(key)
        pendingTranslationJobs.append(
            TranslationJob(
                key: key,
                target: .transcript(
                    sessionID: sessionID,
                    generation: generation,
                    sentence: sentence
                )
            )
        )
        if uiTestTranslationProvider == nil {
            requestNativeTranslationTask()
        }
        scheduleUITestTranslationIfNeeded(for: pendingTranslationJobs[pendingTranslationJobs.count - 1])
    }

    private func queuePreviewTranslation(for text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = cleaned.split(whereSeparator: \.isWhitespace).count
        let endsSentence = cleaned.range(of: #"[.!?]$"#, options: .regularExpression) != nil
        guard wordCount >= 3 || endsSentence else { return }
        guard cleaned != lastQueuedPreviewTranslation else { return }
        let previous = lastQueuedPreviewTranslation
        let wordDelta = wordCount - previous.split(whereSeparator: \.isWhitespace).count
        let shouldQueue = previous.isEmpty
            || endsSentence
            || !normalizedPreview(cleaned).hasPrefix(normalizedPreview(previous))
            || wordDelta >= 3
        guard shouldQueue else { return }
        let key = TranslationJob.livePreviewKey(cleaned)
        guard !pendingTranslationKeys.contains(key) else { return }
        lastQueuedPreviewTranslation = cleaned
        pendingTranslationKeys.insert(key)
        pendingTranslationJobs.append(
            TranslationJob(
                key: key,
                target: .livePreview(text: cleaned)
            )
        )
        if uiTestTranslationProvider == nil {
            requestNativeTranslationTask()
        }
        scheduleUITestTranslationIfNeeded(for: pendingTranslationJobs[pendingTranslationJobs.count - 1])
    }

    @available(macOS 26.4, *)
    func runTranslationTask(_ session: TranslationSession) async {
        translationTaskScheduled = false
        let jobs = dequeueTranslationJobs()
        guard !jobs.isEmpty else { return }

        guard !translationTaskRunning else {
            requeueTranslationJobs(jobs)
            requestNativeTranslationTask()
            return
        }
        translationTaskRunning = true
#if canImport(Translation)
        activeTranslationSession = session
#endif
        defer {
#if canImport(Translation)
            if activeTranslationSession === session {
                activeTranslationSession = nil
            }
#endif
            translationTaskRunning = false
            if !pendingTranslationJobs.isEmpty, translationRetryTask == nil {
                requestNativeTranslationTask()
            }
        }

        do {
            try await session.prepareTranslation()
            let jobsByKey = Dictionary(uniqueKeysWithValues: jobs.map { ($0.key, $0) })
            nonisolated(unsafe) let requests = jobs.map {
                TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: $0.key)
            }
            var failedJobs: [TranslationJob] = []
            var completedKeys = Set<String>()
            for try await response in session.translate(batch: requests) {
                guard let key = response.clientIdentifier,
                      let job = jobsByKey[key] else {
                    continue
                }
                guard !isTranslationJobCancelled(job) else { continue }
                completedKeys.insert(key)
                if !applyTranslation(response.targetText, for: job) {
                    failedJobs.append(job)
                }
            }
            failedJobs.append(contentsOf: jobs.filter {
                !completedKeys.contains($0.key) && !isTranslationJobCancelled($0)
            })
            if !failedJobs.isEmpty {
                handleTranslationFailures(failedJobs)
            }
        } catch {
            let activeJobs = jobs.filter { !isTranslationJobCancelled($0) }
            if !activeJobs.isEmpty {
                handleTranslationFailures(activeJobs)
                persistenceStatus = "English to Chinese translation is not ready."
            }
        }
    }

    private func requestNativeTranslationTask() {
        guard !translationTaskRunning,
              !translationTaskScheduled,
              translationRetryTask == nil else {
            return
        }
        translationTaskScheduled = true
        translationRequestVersion += 1
    }

    private func dequeueTranslationJobs() -> [TranslationJob] {
        let jobs = pendingTranslationJobs
        pendingTranslationJobs.removeAll()
        pendingTranslationKeys.removeAll()
        return jobs
    }

    private func requeueTranslationJobs(_ jobs: [TranslationJob]) {
        for job in jobs {
            pendingTranslationKeys.insert(job.key)
        }
        pendingTranslationJobs.insert(contentsOf: jobs, at: 0)
        if uiTestTranslationProvider == nil {
            scheduleTranslationRetry()
        } else {
            for job in jobs {
                scheduleUITestTranslationIfNeeded(for: job)
            }
        }
    }

    private func handleTranslationFailures(_ jobs: [TranslationJob]) {
        var retryJobs: [TranslationJob] = []
        var completedSessionIDs = Set<UUID>()
        for job in jobs {
            let attempts = translationAttemptCounts[job.key, default: 0] + 1
            translationAttemptCounts[job.key] = attempts
            if attempts < 3 {
                retryJobs.append(job)
            } else {
                translationAttemptCounts[job.key] = nil
                pendingTranslationKeys.remove(job.key)
                if case let .transcript(sessionID, _, _) = job.target {
                    completedSessionIDs.insert(sessionID)
                }
            }
        }
        if !retryJobs.isEmpty {
            requeueTranslationJobs(retryJobs)
        }
        for sessionID in completedSessionIDs {
            completePendingFinalSave(sessionID, allowingMissingTranslations: true)
        }
    }

    @discardableResult
    private func applyTranslation(_ translatedText: String, for job: TranslationJob) -> Bool {
        let cleaned = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        switch job.target {
        case let .transcript(sessionID, generation, sentence):
            guard let session = store.session(id: sessionID),
                  transcriptGenerations[sessionID, default: 0] == generation,
                  session.transcript.contains(where: { existing in
                      existing.id == sentence.id
                          && existing.startTime == sentence.startTime
                          && existing.endTime == sentence.endTime
                          && existing.text == sentence.text
                  }) else { return true }
            var sentence = sentence
            sentence.translation = cleaned
            var updatedStore = store
            try? updatedStore.upsertTranscript(in: sessionID, sentence: sentence)
            store = updatedStore
            translationAttemptCounts[job.key] = nil
            persist()
            completePendingFinalSaveIfReady(sessionID)
            if persistenceStatus == "English to Chinese translation is not ready." {
                persistenceStatus = nil
            }
            return true
        case let .livePreview(text):
            let currentPreview = normalizedPreview(liveTranscriptPreview)
            let translatedPreview = normalizedPreview(text)
            guard currentPreview == translatedPreview || currentPreview.hasPrefix(translatedPreview) else {
                return true
            }
            liveTranslationPreview = cleaned
            translationAttemptCounts[job.key] = nil
            return true
        }
    }

    private func updateLivePreview(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if cleaned != liveTranscriptPreview {
            liveTranscriptPreview = cleaned
            if !normalizedPreview(cleaned).hasPrefix(normalizedPreview(lastQueuedPreviewTranslation)) {
                liveTranslationPreview = ""
            }
        }
        queuePreviewTranslation(for: cleaned)
    }

    private func normalizedPreview(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                String(word).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func resetLivePreview() {
        liveTranscriptPreview = ""
        liveTranslationPreview = ""
        lastQueuedPreviewTranslation = ""
    }

    private func scheduleTranslationRetry() {
        guard translationRetryTask == nil else { return }
        translationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.translationRetryTask = nil
            if !self.pendingTranslationJobs.isEmpty {
                self.requestNativeTranslationTask()
            }
        }
    }

    private func scheduleUITestTranslationIfNeeded(for job: TranslationJob) {
        guard uiTestTranslationProvider != nil else { return }
        guard !uiTestTranslationHangs else { return }
        Task { @MainActor [weak self] in
            let delay = self?.uiTestTranslationDelayNanoseconds ?? 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            self?.completeUITestTranslation(for: job)
        }
    }

    private func completeUITestTranslation(for job: TranslationJob) {
        guard let provider = uiTestTranslationProvider else {
            return
        }
        guard let translation = provider(job.sourceText),
              applyTranslation(translation, for: job) else {
            pendingTranslationJobs.removeAll { $0.key == job.key }
            pendingTranslationKeys.remove(job.key)
            handleTranslationFailures([job])
            return
        }
        pendingTranslationJobs.removeAll { $0.key == job.key }
        pendingTranslationKeys.remove(job.key)
    }

    private func retryRecoveredInferenceIfReady() {
        guard inferenceRunner != nil else { return }
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
            runInference(for: retry.0, audioURL: retry.1)
        }
    }

    private func createUITestAudioFixtures() {
        guard let sessionFileStore else { return }
        for session in store.sessions {
            guard let audioFileName = session.audioFileName else {
                continue
            }
            let audioURL = sessionFileStore.localFileURL(relativePath: audioFileName)
            try? FileManager.default.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: audioURL.path) {
                try? AudioFixtureWriter.writeSineWaveM4A(to: audioURL, durationSeconds: 1)
            }
        }
    }

    private func applyInferenceOutput(
        id: UUID,
        output: RecordingPipelineOutput
    ) {
        var updatedStore = store
        let audioFileName = store.session(id: id)?.audioFileName ?? audioFileName(for: id)
        let savedTitle = restoredTitle(for: store.session(id: id))
        let liveTranscript = sanitizedTranscript(store.session(id: id)?.transcript ?? [])
        let generatedTranscript = sanitizedTranscript(output.transcript)
        let translatedGeneratedTranscript = transcriptPreservingTranslations(
            generatedTranscript,
            from: liveTranscript
        )
        let transcript = TranscriptFinalizationPolicy.chooseTranscript(
            generated: translatedGeneratedTranscript,
            live: liveTranscript
        )
        guard !transcript.isEmpty else {
            markFinalInferenceFailed(id, error: RecordingPipelineError.runtimeFailed("No speech was detected."))
            return
        }
        let durationSeconds = max(
            finalizingDurations[id] ?? 0,
            Int(output.metrics.audioDurationSeconds.rounded())
        )
        cancelTranslationJobs(for: id)
        let generation = transcriptGenerations[id, default: 0] + 1
        transcriptGenerations[id] = generation
        clearCancelledTranslationGenerations(for: id)
        try? updatedStore.replaceGeneratedContent(
            in: id,
            transcript: transcript
        )
        if transcript.contains(where: { $0.translation.isEmpty }) {
            try? updatedStore.finalizeRecording(id, progress: 0.75)
        }
        store = updatedStore
        recordingClocks[id] = nil
        activeAudioURLs[id] = nil
        persist()
        pendingFinalSaves[id] = PendingFinalSave(
            durationSeconds: durationSeconds,
            audioFileName: audioFileName,
            title: savedTitle,
            generation: generation
        )
        for sentence in transcript where sentence.translation.isEmpty {
            queueTranslation(for: sentence, in: id)
        }
        if transcript.contains(where: { $0.translation.isEmpty }) {
            scheduleFinalSaveTimeout(for: id, generation: generation)
        }
        completePendingFinalSaveIfReady(id)
    }

    private func applyInferenceFailure(
        id: UUID,
        error: Error
    ) {
        markFinalInferenceFailed(id, error: error)
    }

    private func markFinalInferenceFailed(_ id: UUID, error: Error) {
        let liveTranscript = sanitizedTranscript(store.session(id: id)?.transcript ?? [])
        guard !liveTranscript.isEmpty else {
            var updatedStore = store
            try? updatedStore.replaceGeneratedContent(in: id, transcript: [])
            store = updatedStore
            markFailed(id, error: error)
            return
        }
        let session = store.session(id: id)
        let durationSeconds = max(
            finalizingDurations[id] ?? 0,
            session?.status.elapsedSeconds ?? 0,
            liveTranscript.map(\.endTime).max() ?? 0
        )
        var updatedStore = store
        try? updatedStore.replaceGeneratedContent(in: id, transcript: liveTranscript)
        try? updatedStore.saveRecording(
            id,
            durationSeconds: durationSeconds,
            audioFileName: session?.audioFileName ?? audioFileName(for: id),
            title: restoredTitle(for: session)
        )
        store = updatedStore
        recordingClocks[id] = nil
        activeAudioURLs[id] = nil
        pendingFinalSaves[id] = nil
        cancelFinalSaveTimeout(for: id)
        finalizingDurations[id] = nil
        persistenceStatus = "Final transcription failed. Saved the live transcript."
        persist()
    }

    private func cancelTranslationJobs(for sessionID: UUID) {
        var removedKeys: [String] = []
        pendingTranslationJobs.removeAll { job in
            if case let .transcript(jobSessionID, _, _) = job.target {
                if jobSessionID == sessionID {
                    removedKeys.append(job.key)
                    return true
                }
            }
            return false
        }
        for key in removedKeys {
            translationAttemptCounts[key] = nil
        }
        pendingTranslationKeys = Set(pendingTranslationJobs.map(\.key))
    }

    private func markTranslationGenerationCancelled(sessionID: UUID, generation: Int) {
        cancelledTranslationGenerationKeys.insert(
            TranslationJob.generationKey(sessionID: sessionID, generation: generation)
        )
    }

    private func clearCancelledTranslationGenerations(for sessionID: UUID) {
        let prefix = "\(sessionID.uuidString)|"
        cancelledTranslationGenerationKeys = cancelledTranslationGenerationKeys.filter {
            !$0.hasPrefix(prefix)
        }
    }

    private func isTranslationGenerationCancelled(sessionID: UUID, generation: Int) -> Bool {
        cancelledTranslationGenerationKeys.contains(
            TranslationJob.generationKey(sessionID: sessionID, generation: generation)
        )
    }

    private func isTranslationJobCancelled(_ job: TranslationJob) -> Bool {
        switch job.target {
        case let .transcript(sessionID, generation, _):
            return isTranslationGenerationCancelled(sessionID: sessionID, generation: generation)
        case .livePreview:
            return false
        }
    }

    private func cancelActiveTranslationSession() {
#if canImport(Translation)
        if #available(macOS 26.0, *) {
            activeTranslationSession?.cancel()
            activeTranslationSession = nil
        }
#endif
    }

    private func completePendingFinalSaveIfReady(_ id: UUID) {
        completePendingFinalSave(id, allowingMissingTranslations: false)
    }

    private func completePendingFinalSave(
        _ id: UUID,
        allowingMissingTranslations: Bool
    ) {
        guard let pendingSave = pendingFinalSaves[id],
              transcriptGenerations[id, default: 0] == pendingSave.generation,
              let session = store.session(id: id) else {
            return
        }
        let hasMissingTranslation = session.transcript.contains {
            $0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard allowingMissingTranslations || !hasMissingTranslation else {
            return
        }
        var updatedStore = store
        try? updatedStore.saveRecording(
            id,
            durationSeconds: pendingSave.durationSeconds,
            audioFileName: pendingSave.audioFileName,
            title: pendingSave.title
        )
        store = updatedStore
        pendingFinalSaves[id] = nil
        cancelFinalSaveTimeout(for: id)
        finalizingDurations[id] = nil
        persist()
    }

    private func scheduleFinalSaveTimeout(for id: UUID, generation: Int) {
        cancelFinalSaveTimeout(for: id)
        let delay = UInt64(max(1, finalSaveTranslationTimeoutSeconds) * 1_000_000_000)
        finalSaveTimeoutTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  self.transcriptGenerations[id, default: 0] == generation,
                  self.pendingFinalSaves[id] != nil else {
                return
            }
            self.markTranslationGenerationCancelled(sessionID: id, generation: generation)
            self.cancelActiveTranslationSession()
            self.cancelTranslationJobs(for: id)
            self.completePendingFinalSave(id, allowingMissingTranslations: true)
        }
    }

    private func cancelFinalSaveTimeout(for id: UUID) {
        finalSaveTimeoutTasks[id]?.cancel()
        finalSaveTimeoutTasks[id] = nil
    }

    private func transcriptPreservingTranslations(
        _ transcript: [TranscriptSentence],
        from existingTranscript: [TranscriptSentence]
    ) -> [TranscriptSentence] {
        let existing = sanitizedTranscript(existingTranscript)
        guard !existing.isEmpty else {
            return transcript
        }
        return transcript.map { sentence in
            guard sentence.translation.isEmpty,
                  let translation = existingTranslation(for: sentence, in: existing) else {
                return sentence
            }
            var translated = sentence
            translated.translation = translation
            return translated
        }
    }

    private func existingTranslation(
        for sentence: TranscriptSentence,
        in existingTranscript: [TranscriptSentence]
    ) -> String? {
        if let match = existingTranscript.first(where: { $0.id == sentence.id }),
           !match.translation.isEmpty {
            return match.translation
        }
        let normalizedText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return existingTranscript.first { existing in
            existing.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
                && !existing.translation.isEmpty
        }?.translation
    }

    private func markFailed(_ id: UUID, error: Error) {
        var updatedStore = store
        try? updatedStore.failRecording(id, message: userFacingMessage(error))
        store = updatedStore
        finalizingDurations[id] = nil
        recordingClocks[id] = nil
        activeAudioURLs[id] = nil
        pendingFinalSaves[id] = nil
        cancelFinalSaveTimeout(for: id)
        transcriptGenerations[id] = nil
        cancelTranslationJobs(for: id)
        liveAudioLevel = 0
        if liveTranscriptionSessionID == id {
            liveTranscriptionStartTask?.cancel()
            liveTranscriptionStartTask = nil
            liveTranscriptionSessionID = nil
            liveTranscriber?.cancel()
        }
        persist()
    }

    private func recordStartFailure(title: String, error: Error) {
        recordingPreparationID = nil
        recordingStartTask = nil
        recordingPreparationTitle = nil
        cancelRecordingPreparationHelp()
        recordingStartFailure = RecordingStartFailure(
            title: title,
            message: userFacingMessage(error)
        )
        liveAudioLevel = 0
    }

    private func updateLiveAudioLevel(_ level: Double) {
        guard selectedSession?.status.acceptsLiveTranscript == true else {
            liveAudioLevel = 0
            return
        }
        liveAudioLevel = level
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

    private func defaultRecordingName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return "Note \(formatter.string(from: Date()))"
    }

    private func sanitizedTranscript(
        _ transcript: [TranscriptSentence],
        maximumEndTime: Int? = nil
    ) -> [TranscriptSentence] {
        transcript.compactMap { sentence in
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            let startTime: Int
            let endTime: Int
            if let maximumEndTime {
                let safeMaximumEndTime = max(1, maximumEndTime)
                startTime = min(max(0, sentence.startTime), max(0, safeMaximumEndTime - 1))
                endTime = min(max(startTime + 1, sentence.endTime), safeMaximumEndTime)
            } else {
                startTime = sentence.startTime
                endTime = sentence.endTime
            }
            return TranscriptSentence(
                id: sentence.id,
                startTime: startTime,
                endTime: endTime,
                text: text,
                translation: sentence.translation.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: sentence.confidence
            )
        }
    }

    private func restoredTitle(for session: RecordingSession?) -> String? {
        guard let session,
              session.title == "Unsaved Recording" else {
            return nil
        }
        return "Recovered Session"
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

    private func userFacingMessage(_ error: Error) -> String {
        if let pipelineError = error as? RecordingPipelineError,
           case let .runtimeFailed(message) = pipelineError {
            if message == "No speech was detected."
                || message.localizedCaseInsensitiveContains("microphone") {
                return message
            }
            return "Local transcription failed."
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
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

private final class WeakAppModelBox: @unchecked Sendable {
    weak var model: AppModel?
}

private struct RecordingClock {
    var baseElapsedSeconds: Int
    var startedAt: Date?
}

struct RecordingStartFailure: Equatable {
    var title: String
    var message: String
}

struct SessionExportStatus: Equatable {
    var sessionID: UUID
    var message: String
    var kind: SessionExportStatusKind
}

enum SessionExportStatusKind: Equatable {
    case success
    case warning
    case failure
    case progress
}

struct LiveSpeechPreview: Equatable, Sendable {
    var text: String
    var translation: String
}

private struct PendingFinalSave: Sendable {
    var durationSeconds: Int
    var audioFileName: String
    var title: String?
    var generation: Int
}

private struct TranslationJob: Sendable {
    var key: String
    var target: TranslationJobTarget

    var sourceText: String {
        switch target {
        case let .transcript(_, _, sentence):
            return sentence.text
        case let .livePreview(text):
            return text
        }
    }

    static func transcriptKey(
        sessionID: UUID,
        generation: Int,
        sentence: TranscriptSentence
    ) -> String {
        "\(sessionID.uuidString)|\(generation)|\(sentence.id.uuidString)|\(sentence.startTime)|\(sentence.endTime)|\(sentence.text)"
    }

    static func generationKey(sessionID: UUID, generation: Int) -> String {
        "\(sessionID.uuidString)|\(generation)"
    }

    static func livePreviewKey(_ text: String) -> String {
        "live-preview|\(text)"
    }
}

private final class AudioStartContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, any Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else {
            return false
        }
        continuation.resume(with: result)
        return true
    }
}

private enum TranslationJobTarget: Sendable {
    case transcript(sessionID: UUID, generation: Int, sentence: TranscriptSentence)
    case livePreview(text: String)
}

private extension RecordingStatus {
    var isPreparing: Bool {
        if case .preparing = self {
            return true
        }
        return false
    }

    var acceptsLiveTranscript: Bool {
        switch self {
        case .recording:
            return true
        case .paused, .preparing, .finalizing, .saved, .recovered, .failed:
            return false
        }
    }

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

private final class UITestAudioRecorder: AudioRecordingControlling, @unchecked Sendable {
    func startRecording(to url: URL) async throws {
        try AudioFixtureWriter.writeSineWaveM4A(to: url, durationSeconds: 1)
    }

    func pauseRecording() {}

    func resumeRecording() throws {}

    func stopRecording() throws -> Int {
        965
    }
}

private final class HangingUITestAudioRecorder: AudioRecordingControlling, @unchecked Sendable {
    func startRecording(to url: URL) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func pauseRecording() {}

    func resumeRecording() throws {}

    func stopRecording() throws -> Int {
        0
    }
}

private final class UITestAudioFileInputProvider: AudioInputProviding, @unchecked Sendable {
    private let audioURL: URL
    private let queue = DispatchQueue(label: "app.livenotes.ui-test-audio-file-input")
    private let lock = NSLock()
    private var stopped = true

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

    func outputFormat() throws -> AVAudioFormat {
        try AVAudioFile(forReading: audioURL).processingFormat
    }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        _ = try outputFormat()
        lock.withLock {
            stopped = false
        }
        queue.async { [audioURL, weak self] in
            guard let self else { return }
            do {
                let file = try AVAudioFile(forReading: audioURL)
                let format = file.processingFormat
                let targetFrameCount = AudioTapBufferSize.frameCount(sampleRate: format.sampleRate)
                while !self.isStopped {
                    let remainingFrames = file.length - file.framePosition
                    guard remainingFrames > 0 else { break }
                    let frameCount = AVAudioFrameCount(min(Int64(targetFrameCount), remainingFrames))
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: frameCount
                    ) else {
                        break
                    }
                    try file.read(into: buffer, frameCount: frameCount)
                    guard buffer.frameLength > 0 else { break }
                    bufferHandler(buffer)
                    Thread.sleep(forTimeInterval: Double(buffer.frameLength) / format.sampleRate)
                }
            } catch {
                return
            }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }
}

private final class HangingUITestLiveTranscriber: LiveTranscriptionRunning, @unchecked Sendable {
    func start(eventHandler: @escaping @Sendable (LiveTranscriptionEvent) -> Void) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func pause() {}

    func resume() {}

    func finish() async -> [TranscriptSentence] {
        []
    }

    func cancel() {}
}

private struct UITestInferenceRunner: RecordingInferenceRunning {
    var output: String = "success"

    func process(audioURL: URL, artifactsRootURL: URL) throws -> RecordingPipelineOutput {
        if output == "throw" {
            throw RecordingPipelineError.runtimeFailed("Local transcription failed.")
        }
        if output == "audio-file-e2e" {
            let durationSeconds = Self.audioDurationSeconds(at: audioURL)
            let roundedDurationSeconds = Int(durationSeconds.rounded())
            return RecordingPipelineOutput(
                transcript: [
                    TranscriptSentence(
                        startTime: 0,
                        endTime: min(roundedDurationSeconds, 7),
                        text: "Today I want to talk about privacy preserving meeting notes.",
                        translation: "今天我想谈谈保护隐私的会议记录。",
                        confidence: .high
                    ),
                    TranscriptSentence(
                        startTime: min(roundedDurationSeconds, 8),
                        endTime: max(roundedDurationSeconds, 12),
                        text: "A reliable local recorder should capture speech, transcribe it, save it, and export a readable transcript.",
                        translation: "可靠的本地录音工具应该捕获语音、转写、保存并导出可读稿件。",
                        confidence: .high
                    )
                ],
                metrics: RecordingPipelineMetrics(
                    audioDurationSeconds: durationSeconds,
                    transcriptSegments: 2,
                    translationSegments: 2
                )
            )
        }
        if output == "short" {
            return RecordingPipelineOutput(
                transcript: [
                    TranscriptSentence(
                        startTime: 0,
                        endTime: 7,
                        text: "Final file transcript.",
                        translation: "",
                        confidence: .high
                    ),
                    TranscriptSentence(
                        startTime: 8,
                        endTime: 22,
                        text: "It has enough coverage to replace the live draft.",
                        translation: "",
                        confidence: .high
                    )
                ],
                metrics: RecordingPipelineMetrics(
                    audioDurationSeconds: 965,
                    transcriptSegments: 2,
                    translationSegments: 0
                )
            )
        }
        if output == "empty" {
            return RecordingPipelineOutput(
                transcript: [
                    TranscriptSentence(
                        startTime: 0,
                        endTime: 1,
                        text: "",
                        translation: "",
                        confidence: .low
                    )
                ],
                metrics: RecordingPipelineMetrics(
                    audioDurationSeconds: 1,
                    transcriptSegments: 1,
                    translationSegments: 0
                )
            )
        }
        let translation = output == "transcript-only"
            ? ""
            : "我们确认了周五前的发布检查清单。"
        let secondTranslation = output == "transcript-only"
            ? ""
            : "录音已保存，并带有转写导出证据。"
        return RecordingPipelineOutput(
            transcript: [
                TranscriptSentence(
                    startTime: 0,
                    endTime: 7,
                    text: "We confirmed the launch checklist before Friday.",
                    translation: translation,
                    confidence: .high
                ),
                TranscriptSentence(
                    startTime: 8,
                    endTime: 22,
                    text: "The recording is saved with transcript export evidence.",
                    translation: secondTranslation,
                    confidence: .high
                )
            ],
            metrics: RecordingPipelineMetrics(
                audioDurationSeconds: 965,
                transcriptSegments: 2,
                translationSegments: output == "transcript-only" ? 0 : 2
            )
        )
    }

    private static func audioDurationSeconds(at audioURL: URL) -> Double {
        guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
            return 22
        }
        return Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)
    }
}

private enum UITestTranslationProvider {
    static func translation(for text: String) -> String? {
        switch text {
        case "We confirmed the launch checklist before Friday.":
            return "我们确认了周五前的发布检查清单。"
        case "The recording is saved with transcript export evidence.":
            return "录音已保存，并带有转写导出证据。"
        case DemoText.livePreview:
            return DemoTranslation.livePreview
        default:
            return nil
        }
    }
}

enum DemoData {
    static func homeStore() -> SessionStore {
        SessionStore(
            sessions: [
                liveSession(),
                savedSession(title: "Customer Update", duration: 1_860),
                savedSession(title: "Research Seminar", duration: 2_820),
                RecordingSession(
                    title: "Design Review",
                    createdAt: Date(timeIntervalSince1970: 1_700),
                    status: .finalizing(progress: 0.62)
                ),
                RecordingSession(
                    title: "Unsaved Recording",
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
                savedSession(title: "Customer Update", duration: 1_860),
                savedSession(title: "Research Seminar", duration: 2_820)
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func longLiveStore() -> SessionStore {
        var session = liveSession()
        session.transcript = (0..<14).map { index in
            TranscriptSentence(
                startTime: index * 12,
                endTime: index * 12 + 8,
                text: "Transcript segment \(index + 1) keeps the recording history visible.",
                translation: "第 \(index + 1) 段转写内容保持可见。",
                confidence: .high
            )
        }
        return SessionStore(
            sessions: [
                session,
                savedSession(title: "Customer Update", duration: 1_860)
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func livePreviewOnlyStore() -> SessionStore {
        let session = RecordingSession(
            id: liveSessionID,
            title: DemoText.primarySessionTitle,
            createdAt: Date(timeIntervalSince1970: 1_825),
            status: .recording(elapsedSeconds: 42),
            audioFileName: "Audio/live-preview-fallback.m4a"
        )
        return SessionStore(
            sessions: [
                session,
                savedSession(title: "Customer Update", duration: 1_860)
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
                savedSession(title: "Customer Update", duration: 1_860),
                savedSession(title: "Research Seminar", duration: 2_820)
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func savedStore() -> SessionStore {
        let saved = savedSession(title: DemoText.primarySessionTitle, duration: 3_120)
        return SessionStore(
            sessions: [
                saved,
                savedSession(title: "Customer Update", duration: 1_860),
                savedSession(title: "Research Seminar", duration: 2_820)
            ],
            selectedSessionID: saved.id
        )
    }

    static func preparingStore() -> SessionStore {
        let preparing = RecordingSession(
            title: "Note 09:30",
            createdAt: Date(timeIntervalSince1970: 1_900),
            status: .preparing
        )
        return SessionStore(
            sessions: [
                preparing,
                savedSession(title: "Customer Update", duration: 1_860)
            ],
            selectedSessionID: preparing.id
        )
    }

    static func failedStore() -> SessionStore {
        let failed = RecordingSession(
            title: "Unfinished Recording",
            createdAt: Date(timeIntervalSince1970: 1_950),
            status: .failed(
                message: "Microphone access is unavailable. Check macOS Microphone privacy settings and try again."
            )
        )
        return SessionStore(
            sessions: [
                failed,
                savedSession(title: "Customer Update", duration: 1_860)
            ],
            selectedSessionID: failed.id
        )
    }

    static func finalizingCompleteStore() -> SessionStore {
        var finalizing = savedSession(title: DemoText.primarySessionTitle, duration: 3_120)
        finalizing.status = .finalizing(progress: 1.0)
        return SessionStore(
            sessions: [
                finalizing,
                savedSession(title: "Customer Update", duration: 1_860)
            ],
            selectedSessionID: finalizing.id
        )
    }

    static func recoveredStore() -> SessionStore {
        let recovered = RecordingSession(
            title: "Unsaved Recording",
            createdAt: Date(timeIntervalSince1970: 1_600),
            status: .recovered(durationSeconds: 2_280),
            audioFileName: "Audio/recovered-audio.m4a"
        )
        return SessionStore(
            sessions: [
                recovered,
                savedSession(title: "Customer Update", duration: 1_860)
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
            title: DemoText.primarySessionTitle,
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
                    text: DemoText.claritySentence,
                    translation: DemoTranslation.claritySentence,
                    confidence: .low
                )
            ]
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
                    startTime: 842,
                    endTime: 851,
                    text: "We start with the customer problem.",
                    translation: DemoTranslation.customerProblem,
                    confidence: .high
                ),
                TranscriptSentence(
                    startTime: 883,
                    endTime: 895,
                    text: DemoText.claritySentence,
                    translation: DemoTranslation.claritySentence,
                    confidence: .high
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

    static let claritySentence = text([
        0x8BF4, 0x8BDD, 0x8005, 0x91CD, 0x590D, 0x4E86, 0x5173,
        0x952E, 0x53E5, 0x5B50, 0xFF0C, 0x4EE5, 0x4FBF, 0x542C,
        0x6E05, 0x3002
    ])

    static let livePreview = text([
        0x6211, 0x4EEC, 0x6B63, 0x5728, 0x68C0, 0x67E5, 0x97F3,
        0x9891, 0xFF0C, 0x5E76, 0x786E, 0x8BA4, 0x8F6C, 0x5199,
        0x5185, 0x5BB9, 0x6E05, 0x6670, 0x3002
    ])

    private static func text(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init)))
    }
}

enum DemoText {
    static let primarySessionTitle = "Morning Session"
    static let livePreview = "We are checking the audio and confirming the transcript is clear."
    static let claritySentence = "The speaker repeats the key sentence for clarity."
}
