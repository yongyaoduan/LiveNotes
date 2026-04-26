import Foundation

public enum SessionStoreError: Error, Equatable {
    case sessionNotFound
}

public struct SessionStore: Sendable {
    public private(set) var sessions: [RecordingSession]
    public private(set) var selectedSessionID: UUID?

    private var now: @Sendable () -> Date

    public init(
        sessions: [RecordingSession] = [],
        selectedSessionID: UUID? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
        self.now = now
    }

    public static func clocked(date: Date) -> SessionStore {
        SessionStore(now: { date })
    }

    @discardableResult
    public mutating func createRecording(named title: String) -> RecordingSession {
        let session = RecordingSession(
            title: title,
            createdAt: now(),
            status: .preparing
        )
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        return session
    }

    @discardableResult
    public mutating func recoverAudio(
        title: String,
        durationSeconds: Int,
        lastSavedAt: Date
    ) -> RecordingSession {
        let session = RecordingSession(
            title: title,
            createdAt: lastSavedAt,
            status: .recovered(durationSeconds: durationSeconds)
        )
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        return session
    }

    public func session(id: UUID) -> RecordingSession? {
        sessions.first { $0.id == id }
    }

    public mutating func selectSession(_ id: UUID) throws {
        guard sessions.contains(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound
        }
        selectedSessionID = id
    }

    public mutating func startRecording(_ id: UUID) throws {
        try updateSession(id) { session in
            session.status = .recording(elapsedSeconds: 0)
        }
    }

    public mutating func pauseRecording(_ id: UUID, elapsedSeconds: Int) throws {
        try updateSession(id) { session in
            session.status = .paused(elapsedSeconds: elapsedSeconds)
        }
    }

    public mutating func finalizeRecording(_ id: UUID, progress: Double) throws {
        try updateSession(id) { session in
            session.status = .finalizing(progress: min(max(progress, 0), 1))
        }
    }

    public mutating func saveRecording(_ id: UUID, durationSeconds: Int) throws {
        try updateSession(id) { session in
            session.status = .saved(durationSeconds: durationSeconds)
        }
    }

    public mutating func appendTranscript(
        to id: UUID,
        sentence: TranscriptSentence
    ) throws {
        try updateSession(id) { session in
            session.transcript.append(sentence)
        }
    }

    public mutating func upsertTopic(
        in id: UUID,
        topic: TopicNote
    ) throws {
        try updateSession(id) { session in
            if let existingIndex = session.topics.firstIndex(where: { $0.id == topic.id }) {
                session.topics[existingIndex] = topic
            } else {
                session.topics.append(topic)
            }
        }
    }

    private mutating func updateSession(
        _ id: UUID,
        update: (inout RecordingSession) -> Void
    ) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound
        }
        update(&sessions[index])
    }
}
