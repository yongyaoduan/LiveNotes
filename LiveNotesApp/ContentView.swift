import SwiftUI

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
        .sheet(isPresented: $model.stopConfirmationVisible) {
            StopRecordingSheet()
        }
    }
}

private struct SessionSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LiveNotes")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LiveNotesStyle.graphite)

            if model.canShowNewRecording {
                Button {
                    model.showNewRecording()
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .help("Start a new local recording.")
            } else {
                Button {
                    model.showNewRecording()
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(true)
                if let reason = model.newRecordingUnavailableReason {
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
                EmptyRecordingsList()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.store.sessions) { session in
                            Button {
                                model.select(session)
                            } label: {
                                SessionRow(
                                    session: session,
                                    selected: session.id == model.store.selectedSessionID
                                )
                            }
                            .buttonStyle(.plain)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No recordings yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiveNotesStyle.graphite)
            Text("Start a recording to build your local library.")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionRow: View {
    var session: RecordingSession
    var selected: Bool

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
    }

    private var statusColor: Color {
        switch session.status {
        case .recording:
            return LiveNotesStyle.recording
        case .paused, .preparing, .finalizing:
            return LiveNotesStyle.secondary
        case .saved:
            return LiveNotesStyle.saved
        case .recovered:
            return LiveNotesStyle.amber
        case .failed:
            return LiveNotesStyle.recording
        }
    }
}

private struct MainSurface: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveNotesStyle.background.ignoresSafeArea()

            if let session = model.selectedSession {
                switch session.status {
                case .preparing:
                    PreparingView(session: session)
                case .finalizing:
                    FinalizingView(session: session)
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
                EmptySelectionView()
            }
        }
    }
}

private struct LiveRecordingView: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 0) {
            TopBar(session: session)

            HStack(spacing: 0) {
                TranscriptColumn(session: session)
                    .frame(maxWidth: .infinity)

                Divider()

                CurrentTopicPanel(session: session)
                    .frame(width: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            RecordingBar(session: session)
                .padding(.bottom, 22)
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
    var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Transcript")
                .font(.system(size: 16, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(session.transcript) { sentence in
                        TranscriptSentenceView(sentence: sentence)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(LiveNotesStyle.recording)
                                .frame(width: 7, height: 7)
                            Text("Listening")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LiveNotesStyle.recording)
                        }
                        Text(session.transcript.isEmpty ? "Waiting for speech..." : "Listening for the next complete sentence...")
                            .font(.system(size: 15))
                            .foregroundStyle(LiveNotesStyle.secondary)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: 780, alignment: .leading)
            }
        }
        .padding(28)
    }
}

private struct TranscriptSentenceView: View {
    var sentence: TranscriptSentence

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(timeLabel(sentence.startTime))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiveNotesStyle.secondary)
                if sentence.confidence == .low {
                    Circle()
                        .fill(LiveNotesStyle.amber)
                        .frame(width: 7, height: 7)
                    Text("Low confidence")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiveNotesStyle.amber)
                }
            }
            Text(sentence.text)
                .font(.system(size: 18))
                .foregroundStyle(LiveNotesStyle.graphite)
            Text("Translation")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text(sentence.translation)
                .font(.system(size: 15))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
    }
}

private struct CurrentTopicPanel: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Current Topic")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if canSplitTopic {
                    Button {
                        model.createNewTopic()
                    } label: {
                        Label("Split Topic", systemImage: "scissors")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier("topic-panel-split-topic-button")
                }
            }

            ScrollView {
                if let topic = currentTopic {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle()
                                .fill(LiveNotesStyle.liveBlue)
                                .frame(width: 3)
                                .clipShape(Capsule())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(topic.title)
                                    .font(.system(size: 17, weight: .semibold))
                                Text(timeRangeLabel(start: topic.startTime, end: topic.endTime))
                                    .font(.system(size: 12))
                                    .foregroundStyle(LiveNotesStyle.secondary)
                            }
                        }

                        if topic.hasSummary {
                            SectionText(title: "Summary", lines: [topic.summary])
                        }
                        if !topic.keyPoints.isEmpty {
                            SectionText(title: "Key Points", lines: topic.keyPoints)
                        }
                        if !topic.hasGeneratedNotes {
                            Text("Notes will appear after more speech is processed.")
                                .font(.system(size: 13))
                                .foregroundStyle(LiveNotesStyle.secondary)
                        }
                        if !topic.questions.isEmpty {
                            SectionText(title: "Questions", lines: topic.questions)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .softPanel()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.currentTopicTitle)
                            .font(.system(size: 17, weight: .semibold))
                        Text("Topic notes will appear after enough speech is processed.")
                            .font(.system(size: 13))
                            .foregroundStyle(LiveNotesStyle.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .softPanel()
                    .accessibilityIdentifier("topic-empty-state")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .scrollIndicators(.automatic)

            Spacer()
        }
        .padding(22)
        .background(LiveNotesStyle.background)
    }

    private var currentTopic: TopicNote? {
        session.topics.last
    }

    private var canSplitTopic: Bool {
        guard let currentTopic else { return false }
        return currentTopic.title == model.currentTopicTitle
            && currentTopic.hasGeneratedNotes
    }
}

private struct RecordingBar: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isPaused ? LiveNotesStyle.secondary : LiveNotesStyle.recording)
                    .frame(width: 8, height: 8)
                Text(session.status.label)
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityIdentifier("recording-duration-label")
                    .accessibilityLabel("Recording duration")
                    .accessibilityValue(session.status.label)
            }
            .frame(minWidth: 128, alignment: .leading)

            RecordingControlButton(
                title: isPaused ? "Resume" : "Pause",
                systemImage: isPaused ? "play.fill" : "pause.fill"
            ) {
                model.togglePause()
            }
            .accessibilityIdentifier("recording-bar-pause-button")

            Button(role: .destructive) {
                model.confirmStop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(LiveNotesStyle.recording)
            .accessibilityIdentifier("recording-bar-stop-button")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.46))
        )
        .shadow(color: .black.opacity(0.11), radius: 18, y: 8)
    }

    private var isPaused: Bool {
        if case .paused = session.status {
            return true
        }
        return false
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
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        let progress = session.status.finalizingProgress ?? 0
        let completed = progress >= 1.0
        VStack(spacing: 18) {
            Text(completed ? "Recording saved" : "Finalizing recording")
                .font(.system(size: 26, weight: .semibold))
            ChecklistRow(text: "Saving audio", done: progress >= 0.20)
            ChecklistRow(text: "Finalizing transcript", done: progress >= 0.50)
            ChecklistRow(text: "Completing topics", done: progress >= 0.75)
            ChecklistRow(text: "Saving notes", done: progress >= 1.00)
            ProgressView(value: progress)
                .frame(width: 360)
            Text(completed ? "Ready to review" : session.status.label)
                .foregroundStyle(LiveNotesStyle.secondary)
            Button(completed ? "Open Review" : "Open When Done") {
                model.openSavedReview()
            }
            .accessibilityIdentifier("open-when-done-button")
            .disabled(progress < 1.0)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreparingView: View {
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing recording")
                .font(.system(size: 26, weight: .semibold))
            Text(session.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text("Checking microphone access and local models.")
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button {
                    model.showNewRecording()
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                if message.localizedCaseInsensitiveContains("microphone") {
                    Button {
                        model.openMicrophoneSettings()
                    } label: {
                        Label("Microphone Settings", systemImage: "mic")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SavedReview: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.title)
                        .font(.system(size: 20, weight: .semibold))
                    Text(session.status.label)
                        .font(.system(size: 12))
                        .foregroundStyle(LiveNotesStyle.secondary)
                }
                Spacer()
                Button {
                    model.exportMarkdown(session)
                } label: {
                    Label("Export Markdown", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("saved-review-export-button")
            }
            .padding(24)
            .background(LiveNotesStyle.surface)

            if let exportStatus = model.exportStatus {
                Text(exportStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(
                        exportStatus == "Exported Markdown"
                            ? LiveNotesStyle.saved
                            : LiveNotesStyle.recording
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(LiveNotesStyle.surface)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(LiveNotesStyle.line).frame(height: 1)
                    }
            }

            GeometryReader { geometry in
                if geometry.size.width < 860 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            SavedTranscriptSection(session: session)
                            Divider()
                            SavedTopicNotesSection(session: session)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    HStack(spacing: 0) {
                        ScrollView {
                            SavedTranscriptSection(session: session)
                                .padding(28)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)

                        Divider()

                        ScrollView {
                            SavedTopicNotesSection(session: session)
                                .padding(24)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(width: min(440, max(360, geometry.size.width * 0.42)))
                    }
                }
            }
        }
    }
}

private struct SavedTranscriptSection: View {
    var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !session.transcript.isEmpty {
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(session.transcript) { sentence in
                    TranscriptSentenceView(sentence: sentence)
                }
            }
        }
    }
}

private struct SavedTopicNotesSection: View {
    var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Topic Notes")
                .font(.system(size: 16, weight: .semibold))
            if session.topics.isEmpty {
                Text("No topics yet")
                    .foregroundStyle(LiveNotesStyle.secondary)
            } else {
                ForEach(session.topics) { topic in
                    SavedTopicCard(topic: topic)
                }
            }
        }
    }
}

private struct SavedTopicCard: View {
    var topic: TopicNote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(topic.title)
                .font(.system(size: 16, weight: .semibold))
            Text(timeRangeLabel(start: topic.startTime, end: topic.endTime))
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
            if topic.hasSummary {
                SectionText(title: "Summary", lines: [topic.summary])
            }
            if !topic.keyPoints.isEmpty {
                SectionText(title: "Key Points", lines: topic.keyPoints)
            }
            if !topic.hasGeneratedNotes {
                Text("Notes will appear after more speech is processed.")
                    .font(.system(size: 13))
                    .foregroundStyle(LiveNotesStyle.secondary)
            }
            if !topic.questions.isEmpty {
                SectionText(title: "Questions", lines: topic.questions)
            }
        }
        .padding(14)
        .softPanel()
    }
}

private struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 14) {
            Text("Recovered Recording")
                .font(.system(size: 24, weight: .semibold))
            Text(session.status.label)
                .foregroundStyle(LiveNotesStyle.secondary)
            Text(session.audioFileName == nil
                 ? "LiveNotes found an unfinished recording in the local library."
                 : "LiveNotes found an unfinished recording with a preserved audio file.")
                .foregroundStyle(LiveNotesStyle.secondary)
            HStack(spacing: 10) {
                Button {
                    model.processRecoveredAudio(session)
                } label: {
                    Label("Process Audio", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canProcessRecoveredAudio(session))
                if model.canShowNewRecording {
                    Button {
                        model.showNewRecording()
                    } label: {
                        Label("New Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("recovered-new-recording-button")
                } else {
                    Button {
                        model.selectActiveRecording()
                    } label: {
                        Label("Return to Active Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("return-to-active-recording-button")
                }
            }
            if let reason = model.recoveredProcessingUnavailableReason(session) {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(LiveNotesStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptySelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Select a recording or start a new one")
                .font(.system(size: 26, weight: .semibold))
            Text("Transcript, translation, topic notes, and local saves.")
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StopRecordingSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stop recording?")
                .font(.system(size: 22, weight: .semibold))
            Text("The recording will finish and the local library will be updated.")
            HStack {
                Spacer()
                Button("Cancel") {
                    model.stopConfirmationVisible = false
                }
                .accessibilityIdentifier("stop-cancel-button")
                Button("Stop and Save") {
                    model.stopAndFinalize()
                }
                .accessibilityIdentifier("stop-save-button")
                .buttonStyle(.borderedProminent)
                .tint(LiveNotesStyle.recording)
            }
        }
        .padding(26)
        .frame(width: 420)
    }
}

private struct NewRecordingSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Recording")
                .font(.system(size: 22, weight: .semibold))
            TextField("Recording Name", text: $model.recordingName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Recording Name")
            if let reason = model.newRecordingUnavailableReason {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(LiveNotesStyle.recording)
                    .accessibilityIdentifier("recording-unavailable-reason")
                if reason.localizedCaseInsensitiveContains("model") {
                    Button {
                        model.openModelInstallLocation()
                    } label: {
                        Label("Open Install Location", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("open-model-install-location-button")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.newRecordingSheetVisible = false
                }
                .accessibilityIdentifier("new-recording-cancel-button")
                Button("Start Recording") {
                    model.requestRecordingConsent()
                }
                .accessibilityIdentifier("new-recording-start-button")
                .disabled(!model.canRequestRecording)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        }
        .padding(26)
        .frame(width: 420)
    }
}

private struct ConsentSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before You Record")
                .font(.system(size: 22, weight: .semibold))
            Text("Make sure you have permission to record this conversation.")
            Toggle("I have permission to record this session.", isOn: $model.consentAccepted)
                .toggleStyle(.checkbox)
            Text("Audio is saved locally by default.")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
            HStack {
                Spacer()
                Button("Back") {
                    model.consentSheetVisible = false
                    model.newRecordingSheetVisible = true
                }
                .accessibilityIdentifier("recording-consent-back-button")
                Button("Start") {
                    model.startRecording()
                }
                .accessibilityIdentifier("recording-consent-start-button")
                .disabled(!model.consentAccepted || !model.canRequestRecording)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        }
        .padding(26)
        .frame(width: 440)
    }
}

private struct SectionText: View {
    var title: String
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            ForEach(displayLines, id: \.self) { line in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(LiveNotesStyle.secondary.opacity(0.55))
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(LiveNotesStyle.graphite)
                }
            }
        }
    }

    private var displayLines: [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension TopicNote {
    var hasSummary: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && summary != "No summary yet."
    }

    var hasGeneratedNotes: Bool {
        hasSummary
            || !keyPoints.isEmpty
            || !questions.isEmpty
    }
}

private struct ChecklistRow: View {
    var text: String
    var done: Bool

    var body: some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? LiveNotesStyle.saved : LiveNotesStyle.secondary)
            Text(text)
        }
        .frame(width: 360, alignment: .leading)
    }
}

private func timeLabel(_ seconds: Int) -> String {
    let safeSeconds = max(0, seconds)
    let minutes = safeSeconds / 60
    let remainingSeconds = safeSeconds % 60
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func timeRangeLabel(start: Int, end: Int?) -> String {
    guard let end else {
        return "\(timeLabel(start)) - now"
    }
    return "\(timeLabel(start)) - \(timeLabel(end))"
}
