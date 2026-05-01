import SwiftUI
#if canImport(_Translation_SwiftUI)
@preconcurrency import _Translation_SwiftUI
#endif
#if canImport(Translation)
@preconcurrency import Translation
#endif

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SessionSidebar()
                .frame(width: 280)
            Divider()
            MainSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LiveNotesStyle.background)
        .sheet(isPresented: $model.newRecordingSheetVisible) {
            NewRecordingSheet()
        }
        .sheet(isPresented: $model.consentSheetVisible) {
            ConsentSheet()
        }
        .alert("Finish Recording?", isPresented: $model.stopConfirmationVisible) {
            Button("Keep Recording", role: .cancel) {
                model.stopConfirmationVisible = false
            }
            .accessibilityIdentifier("stop-cancel-button")
            Button("Finish & Save") {
                model.stopAndFinalize()
            }
            .accessibilityIdentifier("stop-save-button")
        } message: {
            Text("LiveNotes will finish the current transcription and translation before saving.")
        }
        .alert("Export Incomplete?", isPresented: $model.partialExportConfirmationVisible) {
            Button("Retry Translation") {
                model.retryPartialExportTranslation()
            }
            Button("Export Anyway") {
                model.confirmPartialExport()
            }
            Button("Cancel", role: .cancel) {
                model.cancelPartialExport()
            }
        } message: {
            Text("Some lines do not have Chinese translations yet. Export anyway will mark them as unavailable.")
        }
        .modifier(TranslationTaskBridge())
    }
}

private struct TranslationTaskBridge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if canImport(_Translation_SwiftUI) && canImport(Translation)
        if #available(macOS 26.4, *) {
            content.modifier(NativeTranslationTaskBridge())
        } else {
            content
        }
#else
        content
#endif
    }
}

#if canImport(_Translation_SwiftUI) && canImport(Translation)
@available(macOS 26.4, *)
private struct NativeTranslationTaskBridge: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.translationRequestVersion) {
                scheduleTranslation()
            }
            .translationTask(configuration) { session in
                await model.runTranslationTask(session)
            }
    }

    private func scheduleTranslation() {
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans"),
                preferredStrategy: .lowLatency
            )
        } else {
            configuration?.invalidate()
        }
    }
}
#endif

private struct SessionSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LiveNotes")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LiveNotesStyle.graphite)

            if model.shouldShowSidebarNewRecording {
                if model.canShowNewRecording {
                    Button {
                        model.showNewRecording()
                    } label: {
                        Label("New Recording", systemImage: "record.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(LiveNotesStyle.recording)
                    .help("Start a new local recording.")
                }
                if let reason = model.sidebarNewRecordingHelp {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(LiveNotesStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Recordings")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
                .padding(.top, 4)

            if model.store.sessions.isEmpty {
                EmptyRecordingsList(preparationTitle: model.recordingPreparationTitle)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.store.sessions) { session in
                            let canSelect = model.canSelect(session)
                            Button {
                                if canSelect {
                                    model.select(session)
                                }
                            } label: {
                                SessionRow(
                                    session: session,
                                    selected: session.id == model.store.selectedSessionID,
                                    enabled: canSelect
                                )
                            }
                            .buttonStyle(.plain)
                            .allowsHitTesting(canSelect)
                            .accessibilityIdentifier("session-\(session.title)")
                            .accessibilityLabel("\(session.title), \(session.status.label)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityElement(children: .contain)
            }

            Spacer()

            if let persistenceStatus = model.persistenceStatus {
                Text(persistenceStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(LiveNotesStyle.recording)
            }
        }
        .padding(18)
        .background(LiveNotesStyle.sidebar)
    }
}

private struct EmptyRecordingsList: View {
    var preparationTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiveNotesStyle.graphite)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        preparationTitle == nil ? "No recordings yet" : "Setup in progress"
    }

    private var subtitle: String {
        if let preparationTitle {
            return "\(preparationTitle) will appear here after recording starts."
        }
        return "Saved recordings will appear here."
    }
}

private struct SessionRow: View {
    var session: RecordingSession
    var selected: Bool
    var enabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(LiveNotesStyle.graphite)
                    .accessibilityIdentifier("session-title-\(session.title)")
                Text(session.status.label)
                    .font(.system(size: 11))
                    .foregroundStyle(LiveNotesStyle.secondary)
                    .accessibilityIdentifier("session-status-\(session.title)")
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? Color.white.opacity(0.70) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(enabled ? 1 : 0.48)
    }

    private var statusColor: Color {
        switch session.status {
        case .recording:
            return LiveNotesStyle.recording
        case .paused, .preparing, .finalizing:
            if case let .finalizing(progress) = session.status, progress >= 1 {
                return LiveNotesStyle.secondary.opacity(0.55)
            }
            return LiveNotesStyle.secondary
        case .saved:
            return LiveNotesStyle.secondary.opacity(0.55)
        case .recovered:
            return LiveNotesStyle.amber
        case .failed:
            return LiveNotesStyle.amber
        }
    }
}

private struct MainSurface: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveNotesStyle.background.ignoresSafeArea()

            if let title = model.recordingPreparationTitle {
                RecordingPreparationView(title: title) {
                    model.cancelRecordingPreparation()
                }
            } else if let failure = model.recordingStartFailure {
                RecordingStartFailedView(failure: failure)
            } else if let session = model.selectedSession {
                switch session.status {
                case .preparing:
                    PreparingView(session: session)
                case .finalizing:
                    if (session.status.finalizingProgress ?? 0) >= 1 {
                        SavedReview(session: session)
                    } else {
                        FinalizingView(session: session)
                    }
                case .saved:
                    SavedReview(session: session)
                case .recovered:
                    RecoveryView(session: session)
                case let .failed(message):
                    FailedView(session: session, message: message)
                default:
                    LiveRecordingView(session: session)
                }
            } else {
                EmptySelectionView(unavailableReason: model.recordingUnavailableReason)
            }
        }
    }
}

private struct RecordingPreparationView: View {
    @EnvironmentObject private var model: AppModel
    var title: String
    var onCancel: () -> Void

    var body: some View {
        PreparationPanel(
            title: title,
            needsHelp: model.recordingPreparationNeedsHelp,
            onCancel: onCancel
        )
    }
}

private struct PreparationPanel: View {
    @EnvironmentObject private var model: AppModel
    var title: String
    var needsHelp: Bool
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if needsHelp {
                Image(systemName: "hourglass")
                    .font(.system(size: 30))
                    .foregroundStyle(LiveNotesStyle.recording)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(needsHelp ? "Waiting for macOS permission" : "Setting up recording")
                .font(.system(size: 26, weight: .semibold))
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)

            VStack(alignment: .leading, spacing: 12) {
                PreflightStatusRow(title: "Microphone access", status: needsHelp ? "Allow in macOS prompt" : "Checking")
                PreflightStatusRow(title: "Speech recognition", status: needsHelp ? "Allow in macOS prompt" : "Checking")
                PreflightStatusRow(title: "Audio input", status: needsHelp ? "Starts after permission" : "Waiting for speech")
                if needsHelp {
                    Text("Allow Microphone and Speech Recognition in the macOS prompts.")
                        .font(.system(size: 12, weight: .medium))
                    Text("LiveNotes will start recording automatically after access is allowed.")
                        .font(.system(size: 12))
                        .foregroundStyle(LiveNotesStyle.secondary)
                }
            }
            .padding(14)
            .frame(width: 420, alignment: .leading)
            .softPanel()

            if needsHelp {
                HStack(spacing: 10) {
                    Button {
                        model.openMicrophoneSettings()
                    } label: {
                        Label("Open Microphone Settings", systemImage: "mic")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        model.openSpeechRecognitionSettings()
                    } label: {
                        Label("Open Speech Recognition Settings", systemImage: "text.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("preparation-cancel-button")
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreflightStatusRow: View {
    var title: String
    var status: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
        case "Ready":
            return LiveNotesStyle.saved
        case "Checking", "Pending":
            return LiveNotesStyle.secondary
        default:
            return LiveNotesStyle.amber
        }
    }
}

private struct LiveRecordingView: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 0) {
            TopBar(session: session)

            TranscriptColumn(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            RecordingBar(session: session)
        }
    }
}

private struct TopBar: View {
    var session: RecordingSession

    var body: some View {
        HStack(spacing: 10) {
            Text(session.title)
                .font(.system(size: 18, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(LiveNotesStyle.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LiveNotesStyle.line).frame(height: 1)
        }
    }

}

private struct TranscriptColumn: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Transcript")
                .font(.system(size: 16, weight: .semibold))

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(displayedTranscript) { sentence in
                            TranscriptSentenceView(
                                sentence: sentence,
                                missingTranslationText: "Translating..."
                            )
                        }

                        if let preview = model.selectedLiveSpeechPreview {
                            LiveSpeechPreviewView(preview: preview, level: model.liveAudioLevel)
                                .id(livePreviewID)
                        }

                        if model.selectedLiveSpeechPreview == nil {
                            let paused = session.status.isPausedForDisplay
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Circle()
                                        .fill(paused ? LiveNotesStyle.secondary : LiveNotesStyle.liveBlue)
                                        .frame(width: 7, height: 7)
                                    Text(paused ? "Paused" : "Listening")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(paused ? LiveNotesStyle.secondary : LiveNotesStyle.liveBlue)
                                }
                                Text(paused ? "Recording is paused." : listeningText)
                                    .font(.system(size: 15))
                                    .foregroundStyle(LiveNotesStyle.secondary)
                                InputActivityMeter(
                                    level: paused ? 0 : model.liveAudioLevel,
                                    paused: paused
                                )
                                .padding(.top, 4)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .softPanel()
                            .padding(.top, 8)
                        }

                        Color.clear
                            .frame(height: 96)
                            .id(transcriptBottomID)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    scrollToCurrentTranscriptEnd(proxy)
                }
                .onChange(of: scrollTrigger) {
                    scrollToCurrentTranscriptEnd(proxy)
                }
            }
        }
        .padding(28)
    }

    private var transcriptBottomID: String {
        "transcript-bottom-\(session.id.uuidString)"
    }

    private var livePreviewID: String {
        "live-preview-\(session.id.uuidString)"
    }

    private var displayedTranscript: [TranscriptSentence] {
        TranscriptUtteranceSegmenter.segment(
            session.transcript,
            translationMode: .preserveMergedTranslations
        )
    }

    private var scrollTrigger: String {
        [
            session.id.uuidString,
            "\(displayedTranscript.count)",
            displayedTranscript.last?.id.uuidString ?? "",
            displayedTranscript.last?.text ?? "",
            displayedTranscript.last?.translation ?? "",
            model.liveTranscriptPreview,
            model.liveTranslationPreview,
            "\(session.status.isPausedForDisplay)"
        ].joined(separator: "|")
    }

    private func scrollToCurrentTranscriptEnd(_ proxy: ScrollViewProxy) {
        let targetID = model.selectedLiveSpeechPreview == nil ? transcriptBottomID : livePreviewID
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
        }
    }

    private var listeningText: String {
        session.transcript.isEmpty
            ? "Listening for speech..."
            : "Listening for the next complete sentence..."
    }
}

private struct InputActivityMeter: View {
    var level: Double
    var paused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index < activeBars ? LiveNotesStyle.liveBlue : LiveNotesStyle.line)
                        .frame(width: 5, height: CGFloat(5 + index % 4 * 3))
                }
            }
            .frame(width: 94, height: 18, alignment: .leading)
        }
    }

    private var activeBars: Int {
        guard !paused, level > 0.08 else { return 0 }
        return max(1, min(12, Int((level * 12).rounded(.up))))
    }

}

private struct LiveSpeechPreviewView: View {
    var preview: LiveSpeechPreview
    var level: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LiveNotesStyle.liveBlue)
                    .frame(width: 7, height: 7)
                Text(liveStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiveNotesStyle.secondary)
            }
            Text(preview.text)
                .font(.system(size: 18))
                .foregroundStyle(LiveNotesStyle.graphite)
            Label("Translation", systemImage: "character.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text(preview.translation.isEmpty ? "Translating..." : preview.translation)
                .font(.system(size: 16))
                .foregroundStyle(preview.translation.isEmpty ? LiveNotesStyle.secondary : LiveNotesStyle.graphite)
            InputActivityMeter(level: level, paused: false)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softPanel()
    }

    private var liveStatus: String {
        level > 0.08 ? "Transcribing" : "Waiting for speech"
    }
}

private struct TranscriptSentenceView: View {
    var sentence: TranscriptSentence
    var missingTranslationText: String

    var body: some View {
        let translationMissing = sentence.translation.isEmpty
        let translationText = translationMissing ? missingTranslationText : sentence.translation
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(timeLabel(sentence.startTime))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiveNotesStyle.secondary)
            }
            Text(sentence.text)
                .font(.system(size: 18))
                .foregroundStyle(LiveNotesStyle.graphite)
            Divider()
            Label("Translation", systemImage: "character.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text(translationText)
                .font(.system(size: 16))
                .foregroundStyle(translationMissing ? LiveNotesStyle.secondary : LiveNotesStyle.graphite)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softPanel()
    }
}

private struct RecordingBar: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isPaused ? LiveNotesStyle.secondary : LiveNotesStyle.recording)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isPaused ? "Paused" : "Recording")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiveNotesStyle.secondary)
                    Text(clockLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LiveNotesStyle.graphite)
                        .accessibilityIdentifier("recording-duration-label")
                        .accessibilityLabel("Recording duration")
                        .accessibilityValue(clockLabel)
                }
            }
            .frame(minWidth: 96, alignment: .leading)

            Spacer(minLength: 18)

            RecordingControlButton(
                title: isPaused ? "Resume" : "Pause",
                systemImage: isPaused ? "play.fill" : "pause.fill"
            ) {
                model.togglePause()
            }
            .accessibilityIdentifier("recording-bar-pause-button")

            Button {
                model.confirmStop()
            } label: {
                Label("Finish & Save", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(LiveNotesStyle.graphite)
            .accessibilityIdentifier("recording-bar-stop-button")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(LiveNotesStyle.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(LiveNotesStyle.line).frame(height: 1)
        }
    }

    private var isPaused: Bool {
        if case .paused = session.status {
            return true
        }
        return false
    }

    private var clockLabel: String {
        switch session.status {
        case let .recording(elapsedSeconds), let .paused(elapsedSeconds):
            return timeLabel(elapsedSeconds)
        default:
            return session.status.label
        }
    }
}

private struct RecordingControlButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

private struct FinalizingView: View {
    var session: RecordingSession

    var body: some View {
        let progress = session.status.finalizingProgress ?? 0
        VStack(spacing: 18) {
            Text("Saving recording")
                .font(.system(size: 26, weight: .semibold))
            Text(session.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Label(
                "Keep LiveNotes open while transcript and translation are saved.",
                systemImage: "checkmark.seal"
            )
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(LiveNotesStyle.graphite)
            .frame(maxWidth: 440)
            ProgressView(value: progress)
                .frame(width: 360)
            Text(session.status.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreparingView: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        PreparationPanel(
            title: session.title,
            needsHelp: model.recordingPreparationNeedsHelp,
            onCancel: model.cancelRecordingPreparation
        )
    }
}

private struct FailedView: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession
    var message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(LiveNotesStyle.amber)
            Text("Recording failed")
                .font(.system(size: 26, weight: .semibold))
            Text(session.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text(message)
                .foregroundStyle(LiveNotesStyle.secondary)
            HStack(spacing: 10) {
                if message.localizedCaseInsensitiveContains("microphone") {
                    Button {
                        model.openMicrophoneSettings()
                    } label: {
                        Label("Open Microphone Settings", systemImage: "mic")
                    }
                    .accessibilityIdentifier("failed-microphone-settings-button")
                    .buttonStyle(.bordered)
                }
                if model.canShowNewRecording {
                    Button {
                        model.showNewRecording()
                    } label: {
                        Label("Try Recording Again", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("failed-retry-recording-button")
                    .buttonStyle(.bordered)
                }
            }
            Text("After changing settings, start a new recording.")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingStartFailedView: View {
    @EnvironmentObject private var model: AppModel
    var failure: RecordingStartFailure

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(LiveNotesStyle.amber)
            Text("Recording failed")
                .font(.system(size: 26, weight: .semibold))
            Text("No recording was created.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text(failure.message)
                .foregroundStyle(LiveNotesStyle.secondary)
            HStack(spacing: 10) {
                if failure.message.localizedCaseInsensitiveContains("microphone") {
                    Button {
                        model.openMicrophoneSettings()
                    } label: {
                        Label("Open Microphone Settings", systemImage: "mic")
                    }
                    .accessibilityIdentifier("failed-microphone-settings-button")
                    .buttonStyle(.bordered)
                }
                if failure.message.localizedCaseInsensitiveContains("transcription")
                    || failure.message.localizedCaseInsensitiveContains("transcribe") {
                    Button {
                        model.openSpeechRecognitionSettings()
                    } label: {
                        Label("Open Speech Recognition Settings", systemImage: "text.bubble")
                    }
                    .accessibilityIdentifier("failed-speech-settings-button")
                    .buttonStyle(.bordered)
                }
                if model.canShowNewRecording {
                    Button {
                        model.retryRecordingStartFailure()
                    } label: {
                        Label("Try Recording Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("failed-retry-recording-button")
                }
            }
            Text(failure.hasSettingsRecovery
                 ? "After changing settings, return here and start again."
                 : "Start again when you are ready.")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension RecordingStartFailure {
    var hasSettingsRecovery: Bool {
        message.localizedCaseInsensitiveContains("microphone")
            || message.localizedCaseInsensitiveContains("transcription")
            || message.localizedCaseInsensitiveContains("transcribe")
    }
}

private struct SavedReview: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 20, weight: .semibold))
                    Text(session.status.label)
                        .font(.system(size: 12))
                        .foregroundStyle(LiveNotesStyle.secondary)
                    if session.hasMissingTranslations {
                        HStack(spacing: 8) {
                            Label("Some translations are unavailable.", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LiveNotesStyle.amber)
                            Button("Retry Translation") {
                                model.retryMissingTranslations(in: session)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        model.exportMarkdown(session)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("saved-review-export-button")
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    if let exportStatus = model.exportStatus(for: session) {
                        Label(
                            exportStatus.message,
                            systemImage: exportStatusIcon(exportStatus.kind)
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(exportStatusColor(exportStatus.kind))
                    }
                }
            }
            .padding(24)
            .background(LiveNotesStyle.surface)

            ScrollView {
                SavedTranscriptSection(session: session)
                    .padding(28)
                    .frame(maxWidth: 980, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id("saved-review-\(session.id.uuidString)")
        }
    }

    private func exportStatusIcon(_ kind: SessionExportStatusKind) -> String {
        switch kind {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .progress:
            return "arrow.clockwise.circle.fill"
        }
    }

    private func exportStatusColor(_ kind: SessionExportStatusKind) -> Color {
        switch kind {
        case .success:
            return LiveNotesStyle.saved
        case .warning:
            return LiveNotesStyle.amber
        case .failure:
            return LiveNotesStyle.recording
        case .progress:
            return LiveNotesStyle.secondary
        }
    }
}

private struct SavedTranscriptSection: View {
    var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !session.transcript.isEmpty {
                Text("Transcript")
                    .font(.system(size: 16, weight: .semibold))
                ForEach(session.transcript) { sentence in
                    TranscriptSentenceView(
                        sentence: sentence,
                        missingTranslationText: "Translation unavailable."
                    )
                }
            }
        }
    }
}

private struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Unsaved Recording")
                    .font(.system(size: 24, weight: .semibold))
                Text("Unsaved recording · \(recoveredDurationLabel(session))")
                    .foregroundStyle(LiveNotesStyle.secondary)
                Text(model.canProcessRecoveredAudio(session)
                     ? "Create a saved transcript and translation from this audio."
                     : "Finish the active recording before recovering this one.")
                    .foregroundStyle(LiveNotesStyle.secondary)
            }

            HStack(spacing: 10) {
                Button("Leave Unsaved") {
                    model.deferRecoveredAudio(session)
                }
                .buttonStyle(.bordered)
                if model.canShowNewRecording {
                    Button {
                        model.processRecoveredAudio(session)
                    } label: {
                        Label("Recover & Save", systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canProcessRecoveredAudio(session))
                } else {
                    Button {
                        model.selectActiveRecording()
                    } label: {
                        Label("Return to Active Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("return-to-active-recording-button")
                }
            }

            if let reason = model.recoveredProcessingUnavailableReason(session),
               reason != "Finish the active recording before recovering this one." {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(LiveNotesStyle.secondary)
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .softPanel()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recoveredDurationLabel(_ session: RecordingSession) -> String {
        guard let seconds = session.status.elapsedSeconds else { return "unknown" }
        return "\(max(0, seconds) / 60) min"
    }
}

private struct EmptySelectionView: View {
    @EnvironmentObject private var model: AppModel
    var unavailableReason: String?

    var body: some View {
        VStack(spacing: 12) {
            if unavailableReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(LiveNotesStyle.amber)
            }
            Text(title)
                .font(.system(size: 26, weight: .semibold))
            Text(subtitle)
                .foregroundStyle(LiveNotesStyle.secondary)
                .multilineTextAlignment(.center)
            if unavailableReason != nil {
                Text("Resolve the issue and try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(LiveNotesStyle.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button {
                    model.showNewRecording()
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(LiveNotesStyle.recording)
                .accessibilityIdentifier("empty-start-recording-button")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -34)
    }

    private var title: String {
        unavailableReason ?? "Ready to record"
    }

    private var subtitle: String {
        if unavailableReason != nil {
            return "Recording is unavailable."
        }
        return "Record locally. Transcription and translation stay on this Mac."
    }
}

private struct NewRecordingSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Recording")
                .font(.system(size: 22, weight: .semibold))
            Text("Transcription and translation run on this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text("Name")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            TextField("Recording Name", text: $model.recordingName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Recording Name")
            if let reason = model.newRecordingUnavailableReason {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(LiveNotesStyle.recording)
                    .accessibilityIdentifier("recording-unavailable-reason")
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.newRecordingSheetVisible = false
                }
                .accessibilityIdentifier("new-recording-cancel-button")
                Button("Start Recording") {
                    model.startRecording()
                }
                .accessibilityIdentifier("new-recording-start-button")
                .disabled(!model.canRequestRecording || !model.consentAccepted)
                .buttonStyle(.borderedProminent)
                .tint(LiveNotesStyle.recording)
            }
        }
        .padding(26)
        .frame(width: 460)
    }
}

private struct ConsentSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before You Record")
                .font(.system(size: 22, weight: .semibold))
            Text("Confirm everyone has agreed to be recorded.")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
            Toggle("I have permission to record this session.", isOn: $model.consentAccepted)
                .toggleStyle(.checkbox)
            if !model.consentAccepted {
                Text("Check the box to continue.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiveNotesStyle.secondary)
            }
            Text("Audio is saved locally by default.")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelRecordingConsent()
                }
                .accessibilityIdentifier("recording-consent-back-button")
                if model.consentAccepted, model.canRequestRecording {
                    Button("Continue") {
                        model.continueAfterRecordingConsent()
                    }
                    .accessibilityIdentifier("recording-consent-start-button")
                    .buttonStyle(.borderedProminent)
                    .tint(LiveNotesStyle.recording)
                } else {
                    Button("Continue") {
                        model.continueAfterRecordingConsent()
                    }
                    .accessibilityIdentifier("recording-consent-start-button")
                    .disabled(true)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(26)
        .frame(width: 440)
    }
}

private extension RecordingStatus {
    var isPausedForDisplay: Bool {
        if case .paused = self {
            return true
        }
        return false
    }
}

private func timeLabel(_ seconds: Int) -> String {
    let safeSeconds = max(0, seconds)
    let minutes = safeSeconds / 60
    let remainingSeconds = safeSeconds % 60
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}
