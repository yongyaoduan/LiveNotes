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
    public mutating func createRecording(
        id: UUID = UUID(),
        named title: String,
        audioFileName: String? = nil
    ) -> RecordingSession {
        let session = RecordingSession(
            id: id,
            title: title,
            createdAt: now(),
            status: .preparing,
            audioFileName: audioFileName
        )
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        return session
    }

    @discardableResult
    public mutating func recoverAudio(
        title: String,
        durationSeconds: Int,
        lastSavedAt: Date,
        audioFileName: String? = nil
    ) -> RecordingSession {
        let session = RecordingSession(
            title: title,
            createdAt: lastSavedAt,
            status: .recovered(durationSeconds: durationSeconds),
            audioFileName: audioFileName
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

    public mutating func startRecording(_ id: UUID, elapsedSeconds: Int = 0) throws {
        try updateSession(id) { session in
            session.status = .recording(elapsedSeconds: elapsedSeconds)
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

    public mutating func saveRecording(
        _ id: UUID,
        durationSeconds: Int,
        audioFileName: String? = nil
    ) throws {
        try updateSession(id) { session in
            session.status = .saved(durationSeconds: durationSeconds)
            if let audioFileName {
                session.audioFileName = audioFileName
            }
        }
    }

    public mutating func failRecording(_ id: UUID, message: String) throws {
        try updateSession(id) { session in
            session.status = .failed(message: message)
        }
    }

    @discardableResult
    public mutating func recoverInterruptedSessions() -> Int {
        var recoveredCount = 0
        for index in sessions.indices {
            guard let durationSeconds = recoveryDuration(for: sessions[index]) else {
                continue
            }
            sessions[index].status = .recovered(durationSeconds: durationSeconds)
            recoveredCount += 1
        }
        return recoveredCount
    }

    public mutating func replaceGeneratedContent(
        in id: UUID,
        transcript: [TranscriptSentence],
        topics: [TopicNote]
    ) throws {
        try updateSession(id) { session in
            session.transcript = transcript
            session.topics = topics
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

    private func recoveryDuration(for session: RecordingSession) -> Int? {
        switch session.status {
        case .preparing:
            return maxRecoveredDuration(session)
        case let .recording(elapsedSeconds),
             let .paused(elapsedSeconds):
            return max(elapsedSeconds, maxRecoveredDuration(session))
        case .finalizing:
            return maxRecoveredDuration(session)
        case .saved, .recovered, .failed:
            return nil
        }
    }

    private func maxRecoveredDuration(_ session: RecordingSession) -> Int {
        max(
            session.transcript.map(\.endTime).max() ?? 0,
            session.topics.compactMap(\.endTime).max() ?? 0
        )
    }
}
