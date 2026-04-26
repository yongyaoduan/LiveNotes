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
        .sheet(isPresented: $model.exportSheetVisible) {
            ExportSheet()
        }
        .sheet(isPresented: $model.settingsSheetVisible) {
            SettingsSheet()
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
            Text("Live Notes")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LiveNotesStyle.graphite)

            Button {
                model.showNewRecording()
            } label: {
                Label("New Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(LiveNotesStyle.recording)

            Text("Recordings")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
                .padding(.top, 4)

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
            }
            .accessibilityElement(children: .contain)

            Spacer()

            TextField("Search", text: .constant(""))
                .textFieldStyle(.roundedBorder)

            Button {
                model.settingsSheetVisible = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Text("Auto-save on")
                .font(.system(size: 11))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .padding(18)
        .background(LiveNotesStyle.sidebar)
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
                case .finalizing:
                    FinalizingView(session: session)
                case .saved:
                    SavedReview(session: session)
                case .recovered:
                    RecoveryView(session: session)
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

            RecordingBar()
                .padding(.bottom, 22)
        }
    }
}

private struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        HStack(spacing: 10) {
            Text(session.title)
                .font(.system(size: 18, weight: .semibold))
            Chip("English → Chinese")
            Chip("Local Only")
            Chip("Saved 2 sec ago")
            Spacer()
            Button("Export") {
                model.exportSheetVisible = true
            }
            .accessibilityIdentifier("topbar-export-button")
            .disabled(!isSaved)
            Button("Stop") {
                model.confirmStop()
            }
            .accessibilityIdentifier("topbar-stop-button")
            .buttonStyle(.borderedProminent)
            .tint(LiveNotesStyle.recording)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(LiveNotesStyle.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LiveNotesStyle.line).frame(height: 1)
        }
    }

    private var isSaved: Bool {
        if case .saved = session.status {
            return true
        }
        return false
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
                        Text("Now we move to optimization and training stability.")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(LiveNotesStyle.graphite)
                        Text("Translation")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LiveNotesStyle.secondary)
                        Text(DemoTranslation.optimization)
                            .font(.system(size: 15))
                            .foregroundStyle(LiveNotesStyle.secondary)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: 780, alignment: .leading)
            }

            Button("Jump to Live") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            Text("Current Topic")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Rectangle()
                        .fill(LiveNotesStyle.liveBlue)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.currentTopicTitle)
                            .font(.system(size: 17, weight: .semibold))
                        Text("14:43 - now")
                            .font(.system(size: 12))
                            .foregroundStyle(LiveNotesStyle.secondary)
                    }
                }

                SectionText(
                    title: "Summary",
                    lines: ["Activation functions add non-linearity so outputs can represent more useful patterns."]
                )
                SectionText(
                    title: "Key Points",
                    lines: [
                        "They transform linear outputs.",
                        "They help deeper models express complex relationships.",
                        "They affect training behavior."
                    ]
                )
                SectionText(
                    title: "Questions",
                    lines: ["Why does non-linearity matter?"]
                )
            }
            .padding(14)
            .softPanel()

            HStack {
                Button("Rename") {}
                Button("New Topic") {
                    model.createNewTopic()
                }
                .accessibilityIdentifier("topic-panel-new-topic-button")
            }
            .controlSize(.small)

            Text("Previous Topics")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiveNotesStyle.secondary)
            Text("Model Parameters")
            Text("Data Preparation")

            Spacer()
        }
        .padding(22)
        .background(Color.white.opacity(0.28))
    }
}

private struct RecordingBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(model.paused ? LiveNotesStyle.secondary : LiveNotesStyle.recording)
                .frame(width: 9, height: 9)
            Text(model.paused ? "Paused" : "15:08")
                .font(.system(size: 13, weight: .medium))

            Capsule()
                .fill(LiveNotesStyle.line)
                .frame(width: 68, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LiveNotesStyle.recording)
                        .frame(width: 42, height: 5)
                }

            Button(model.paused ? "Resume" : "Pause") {
                model.togglePause()
            }
            .accessibilityIdentifier("recording-bar-pause-button")
            Button("New Topic") {
                model.createNewTopic()
            }
            .accessibilityIdentifier("recording-bar-new-topic-button")
            Button("Bookmark") {}
            Button("Stop") {
                model.confirmStop()
            }
            .accessibilityIdentifier("recording-bar-stop-button")

            Text(model.paused ? "Paused" : "Recording · AI catching up · Auto-saved")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
    }
}

private struct FinalizingView: View {
    @EnvironmentObject private var model: AppModel
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 18) {
            Text("Finalizing recording")
                .font(.system(size: 26, weight: .semibold))
            ChecklistRow(text: "Saving audio", done: true)
            ChecklistRow(text: "Finalizing transcript", done: false)
            ChecklistRow(text: "Completing topics", done: false)
            ChecklistRow(text: "Saving notes", done: false)
            ProgressView(value: 0.62)
                .frame(width: 360)
            Text("You can close this window. Saving continues in the background.")
                .foregroundStyle(LiveNotesStyle.secondary)
            HStack {
                Button("Keep Working") {}
                Button("Open When Done") {
                    model.openSavedReview()
                }
                .buttonStyle(.borderedProminent)
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
                    Text("Saved today 10:02")
                        .font(.system(size: 12))
                        .foregroundStyle(LiveNotesStyle.secondary)
                }
                Spacer()
                Button("Export") {
                    model.exportSheetVisible = true
                }
                .accessibilityIdentifier("saved-review-export-button")
            }
            .padding(24)
            .background(LiveNotesStyle.surface)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Topics")
                        .font(.system(size: 15, weight: .semibold))
                    ForEach(session.topics) { topic in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.title)
                                .font(.system(size: 13, weight: topic.title == "Activation Functions" ? .semibold : .regular))
                            Text(timeRangeLabel(start: topic.startTime, end: topic.endTime))
                                .font(.system(size: 11))
                                .foregroundStyle(LiveNotesStyle.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(width: 260)
                .background(Color.white.opacity(0.24))

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Activation Functions")
                            .font(.system(size: 24, weight: .semibold))
                        Spacer()
                        Picker("", selection: .constant("Notes")) {
                            Text("Notes").tag("Notes")
                            Text("Transcript").tag("Transcript")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    SectionText(title: "Summary", lines: [DemoData.activationTopic.summary])
                    SectionText(title: "Key Points", lines: DemoData.activationTopic.keyPoints)
                    SectionText(title: "Questions", lines: DemoData.activationTopic.questions)
                    Text("Transcript Links")
                        .font(.system(size: 13, weight: .semibold))
                    Text("14:47 · Jump to audio")
                        .foregroundStyle(LiveNotesStyle.liveBlue)
                    Spacer()
                    AudioStrip()
                }
                .padding(28)
            }
        }
    }
}

private struct RecoveryView: View {
    var session: RecordingSession

    var body: some View {
        VStack(spacing: 14) {
            Text("Recovered Recording")
                .font(.system(size: 24, weight: .semibold))
            Text("38 min · Last saved 09:42 · Audio intact")
                .foregroundStyle(LiveNotesStyle.secondary)
            Text("Live Notes found an unfinished recording.")
            HStack {
                Button("Recover Session") {}
                Button("Delete Recording", role: .destructive) {}
                Button("Show in Finder") {}
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
            Text("Live transcription, translation, topic notes, and saved audio.")
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
            Text("The audio and notes will be saved automatically.")
            HStack {
                Spacer()
                Button("Cancel") {
                    model.stopConfirmationVisible = false
                }
                Button("Stop and Save") {
                    model.stopAndFinalize()
                }
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
            LabeledContent("Spoken Language") {
                Text(model.spokenLanguage)
            }
            LabeledContent("Translate To") {
                Text(model.translateTo)
            }
            LabeledContent("Mode") {
                Text("Local Only")
            }
            LabeledContent("Audio Input") {
                Text("MacBook Pro Microphone")
            }
            LabeledContent("Save To") {
                Text("Live Notes Library")
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
                .buttonStyle(.borderedProminent)
                .tint(LiveNotesStyle.recording)
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
                Button("Start") {
                    model.startRecording()
                }
                .disabled(!model.consentAccepted)
                .buttonStyle(.borderedProminent)
                .tint(LiveNotesStyle.recording)
            }
        }
        .padding(26)
        .frame(width: 440)
    }
}

private struct ExportSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Export")
                    .font(.system(size: 22, weight: .semibold))
                Text("Markdown")
                Text("PDF")
                Text("TXT")
                Text("SRT")
                Text("VTT")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Content")
                    .font(.system(size: 15, weight: .semibold))
                Toggle("Topic Notes", isOn: .constant(true))
                Toggle("Transcript", isOn: .constant(true))
                Toggle("Translation", isOn: .constant(true))
                Toggle("Audio Timestamps", isOn: .constant(true))
                Text("Destination is not writable")
                    .font(.system(size: 12))
                    .foregroundStyle(LiveNotesStyle.amber)
                Button("Choose Another Folder") {}
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview")
                    .font(.system(size: 15, weight: .semibold))
                Text("# Neural Networks")
                Text("## Activation Functions")
                Text("- They transform linear outputs.")
                Text("[14:43] Activation functions turn linear outputs into useful signals.")
                    .font(.system(size: 12))
                    .foregroundStyle(LiveNotesStyle.secondary)
                Spacer()
                HStack {
                Button("Cancel") {
                    model.exportSheetVisible = false
                }
                    .accessibilityIdentifier("export-cancel-button")
                Button("Export") {
                    model.exportSheetVisible = false
                }
                    .accessibilityIdentifier("export-confirm-button")
                .buttonStyle(.borderedProminent)
            }
            }
            .frame(width: 300)
        }
        .padding(26)
        .frame(width: 760, height: 420)
    }
}

private struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 22, weight: .semibold))
            SettingsRow("Audio Input", value: "MacBook Pro Microphone")
            SettingsRow("Recording Quality", value: "Balanced")
            SettingsRow("Spoken Language", value: "Auto")
            SettingsRow("Translate To", value: "Chinese")
            SettingsRow("Mode", value: "Local Only")
            SettingsRow("Local Models", value: model.localModelStatus)
            SettingsRow("Save Location", value: "Live Notes Library")
            SettingsRow("Default Export", value: "Markdown")
            Text("Audio and notes stay on this Mac in Local Only mode.")
                .font(.system(size: 12))
                .foregroundStyle(LiveNotesStyle.secondary)
            HStack {
                Spacer()
                Button("Done") {
                    model.settingsSheetVisible = false
                }
            }
        }
        .padding(26)
        .frame(width: 460)
    }
}

private struct SectionText: View {
    var title: String
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            ForEach(lines, id: \.self) { line in
                Text("• \(line)")
                    .font(.system(size: 13))
                    .foregroundStyle(LiveNotesStyle.graphite)
            }
        }
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

private struct AudioStrip: View {
    var body: some View {
        HStack {
            Button("Play") {}
            Text("14:43")
            Capsule()
                .fill(LiveNotesStyle.line)
                .frame(height: 5)
            Text("1.25x")
        }
    }
}

private struct Chip: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(LiveNotesStyle.line)
            )
    }
}

private func SettingsRow(_ title: String, value: String) -> some View {
    HStack {
        Text(title)
        Spacer()
        Text(value)
            .foregroundStyle(LiveNotesStyle.secondary)
    }
}

private func timeLabel(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func timeRangeLabel(start: Int, end: Int?) -> String {
    guard let end else {
        return "\(timeLabel(start)) - now"
    }
    return "\(timeLabel(start)) - \(timeLabel(end))"
}
