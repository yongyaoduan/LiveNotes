import Foundation
import SwiftUI

final class AppModel: ObservableObject {
    @Published var store: SessionStore
    @Published var newRecordingSheetVisible = false
    @Published var consentSheetVisible = false
    @Published var exportSheetVisible = false
    @Published var settingsSheetVisible = false
    @Published var stopConfirmationVisible = false
    @Published var consentAccepted = false
    @Published var recordingName = "Untitled Recording"
    @Published var spokenLanguage = "Auto"
    @Published var translateTo = "Chinese"
    @Published var currentTopicTitle = "Activation Functions"
    @Published var paused = false
    @Published var localModelStatus: String

    private let sessionFileStore: SessionFileStore?

    init(
        store: SessionStore,
        sessionFileStore: SessionFileStore? = nil,
        localModelStatus: String = "Ready"
    ) {
        self.store = store
        self.sessionFileStore = sessionFileStore
        self.localModelStatus = localModelStatus
    }

    static func launchModel(arguments: [String]) -> AppModel {
        if arguments.contains("--ui-test") {
            return uiTestModel(arguments: arguments)
        }
        let fileStore = SessionFileStore(url: defaultSessionStoreURL())
        let sessions = (try? fileStore.load()) ?? []
        let selectedSessionID = sessions.first?.id
        return AppModel(
            store: SessionStore(sessions: sessions, selectedSessionID: selectedSessionID),
            sessionFileStore: fileStore,
            localModelStatus: bundledModelStatus()
        )
    }

    private static func uiTestModel(arguments: [String]) -> AppModel {
        if let stateIndex = arguments.firstIndex(of: "--ui-state"),
           arguments.indices.contains(stateIndex + 1) {
            switch arguments[stateIndex + 1] {
            case "saved":
                return AppModel(store: DemoData.savedStore())
            case "live":
                return AppModel(store: DemoData.liveStore())
            default:
                return AppModel(store: DemoData.homeStore())
            }
        }
        return AppModel(store: DemoData.homeStore())
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

    func select(_ session: RecordingSession) {
        try? store.selectSession(session.id)
    }

    func showNewRecording() {
        recordingName = "Untitled Recording"
        consentAccepted = false
        newRecordingSheetVisible = true
    }

    func requestRecordingConsent() {
        newRecordingSheetVisible = false
        consentSheetVisible = true
    }

    func startRecording() {
        let session = store.createRecording(named: recordingName.isEmpty ? "Untitled Recording" : recordingName)
        try? store.startRecording(session.id)
        appendDemoContent(to: session.id)
        consentSheetVisible = false
        consentAccepted = false
        currentTopicTitle = "Activation Functions"
        paused = false
        persist()
    }

    func togglePause() {
        guard let id = store.selectedSessionID else { return }
        if paused {
            try? store.startRecording(id)
            paused = false
        } else {
            try? store.pauseRecording(id, elapsedSeconds: 908)
            paused = true
        }
        persist()
    }

    func createNewTopic() {
        currentTopicTitle = "Optimization"
        guard let id = store.selectedSessionID else { return }
        try? store.upsertTopic(
            in: id,
            topic: TopicNote(
                title: "Optimization",
                startTime: 908,
                endTime: nil,
                summary: "Listening for key points...",
                keyPoints: [],
                questions: []
            )
        )
        persist()
    }

    func confirmStop() {
        stopConfirmationVisible = true
    }

    func stopAndFinalize() {
        guard let id = store.selectedSessionID else { return }
        try? store.finalizeRecording(id, progress: 0.62)
        stopConfirmationVisible = false
        paused = false
        persist()
    }

    func openSavedReview() {
        guard let id = store.selectedSessionID else { return }
        try? store.saveRecording(id, durationSeconds: 3_120)
        persist()
    }

    private func appendDemoContent(to sessionID: UUID) {
        try? store.appendTranscript(
            to: sessionID,
            sentence: TranscriptSentence(
                startTime: 883,
                endTime: 895,
                text: "Activation functions turn linear outputs into useful signals.",
                translation: DemoTranslation.activationFunctions,
                confidence: .high
            )
        )
        try? store.upsertTopic(
            in: sessionID,
            topic: DemoData.activationTopic
        )
    }

    private func persist() {
        try? sessionFileStore?.save(store.sessions)
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

    private static func bundledModelStatus() -> String {
        let locator = LocalModelBundleLocator()
        return locator
            .validateFirstReadyRoot(
                bundleResourceURL: Bundle.main.resourceURL,
                applicationSupportArtifactsURL: locator.applicationSupportArtifactsURL()
            )
            .userFacingStatus
    }
}

enum DemoData {
    static let activationTopic = TopicNote(
        title: "Activation Functions",
        startTime: 883,
        endTime: 1_289,
        summary: "Activation functions add non-linearity so model outputs can represent more useful patterns.",
        keyPoints: [
            "They transform linear outputs.",
            "They help deeper models express complex relationships.",
            "They are part of the model design."
        ],
        questions: [
            "Why does non-linearity matter?"
        ]
    )

    static func homeStore() -> SessionStore {
        SessionStore(
            sessions: [
                liveSession(),
                savedSession(title: "Product Sync", duration: 1_860),
                savedSession(title: "Week 6 Notes", duration: 2_820),
                RecordingSession(
                    title: "Design Review",
                    createdAt: Date(timeIntervalSince1970: 1_700),
                    status: .finalizing(progress: 0.62)
                ),
                RecordingSession(
                    title: "Recovered Audio",
                    createdAt: Date(timeIntervalSince1970: 1_600),
                    status: .recovered(durationSeconds: 2_280)
                )
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func liveStore() -> SessionStore {
        SessionStore(
            sessions: [
                liveSession(),
                savedSession(title: "Product Sync", duration: 1_860),
                savedSession(title: "Week 6 Notes", duration: 2_820)
            ],
            selectedSessionID: liveSessionID
        )
    }

    static func savedStore() -> SessionStore {
        let saved = savedSession(title: "Neural Networks", duration: 3_120)
        return SessionStore(
            sessions: [
                saved,
                savedSession(title: "Product Sync", duration: 1_860),
                savedSession(title: "Week 6 Notes", duration: 2_820)
            ],
            selectedSessionID: saved.id
        )
    }

    private static let liveSessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private static func liveSession() -> RecordingSession {
        RecordingSession(
            id: liveSessionID,
            title: "Neural Networks",
            createdAt: Date(timeIntervalSince1970: 1_800),
            status: .recording(elapsedSeconds: 908),
            transcript: [
                TranscriptSentence(
                    startTime: 842,
                    endTime: 851,
                    text: "We start with model parameters.",
                    translation: DemoTranslation.parameters,
                    confidence: .high
                ),
                TranscriptSentence(
                    startTime: 883,
                    endTime: 895,
                    text: "Activation functions turn linear outputs into useful signals.",
                    translation: DemoTranslation.activationFunctions,
                    confidence: .low
                )
            ],
            topics: [activationTopic]
        )
    }

    private static func savedSession(title: String, duration: Int) -> RecordingSession {
        RecordingSession(
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_500),
            status: .saved(durationSeconds: duration),
            transcript: [
                TranscriptSentence(
                    startTime: 883,
                    endTime: 895,
                    text: "Activation functions turn linear outputs into useful signals.",
                    translation: DemoTranslation.activationFunctions,
                    confidence: .high
                )
            ],
            topics: [
                TopicNote(
                    title: "Course Practice",
                    startTime: 0,
                    endTime: 491,
                    summary: "Practice steps and expectations are introduced.",
                    keyPoints: ["Review the practice steps."],
                    questions: []
                ),
                TopicNote(
                    title: "CNN Training Task",
                    startTime: 492,
                    endTime: 882,
                    summary: "The task setup and training goal are explained.",
                    keyPoints: ["Inputs are normalized before training."],
                    questions: []
                ),
                activationTopic,
                TopicNote(
                    title: "Model Parameters",
                    startTime: 1_290,
                    endTime: 2_046,
                    summary: "Parameters and learned values are compared.",
                    keyPoints: ["Parameters are updated during training."],
                    questions: []
                )
            ]
        )
    }
}

enum DemoTranslation {
    static let parameters = text([
        0x53C2, 0x6570, 0x662F, 0x4ECE, 0x6570, 0x636E, 0x4E2D,
        0x5B66, 0x4E60, 0x5230, 0x7684, 0x503C, 0x3002
    ])

    static let activationFunctions = text([
        0x6FC0, 0x6D3B, 0x51FD, 0x6570, 0x5E2E, 0x52A9, 0x6A21, 0x578B,
        0x5B66, 0x4E60, 0x975E, 0x7EBF, 0x6027, 0x6A21, 0x5F0F, 0x3002
    ])

    static let optimization = text([
        0x4F18, 0x5316, 0x4F1A, 0x8C03, 0x6574, 0x6A21, 0x578B, 0x53C2,
        0x6570, 0x4EE5, 0x51CF, 0x5C11, 0x8BEF, 0x5DEE, 0x3002
    ])

    private static func text(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init)))
    }
}
