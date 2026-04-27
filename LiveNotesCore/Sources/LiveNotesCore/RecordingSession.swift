import Foundation

public struct RecordingSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var status: RecordingStatus
    public var audioFileName: String?
    public var transcript: [TranscriptSentence]
    public var topics: [TopicNote]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        status: RecordingStatus,
        audioFileName: String? = nil,
        transcript: [TranscriptSentence] = [],
        topics: [TopicNote] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.status = status
        self.audioFileName = audioFileName
        self.transcript = transcript
        self.topics = topics
    }
}

public enum RecordingStatus: Codable, Equatable, Sendable {
    case preparing
    case recording(elapsedSeconds: Int)
    case paused(elapsedSeconds: Int)
    case finalizing(progress: Double)
    case saved(durationSeconds: Int)
    case recovered(durationSeconds: Int)
    case failed(message: String)

    public var label: String {
        switch self {
        case .preparing:
            return "Preparing"
        case let .recording(elapsedSeconds):
            return "Recording · \(Self.clockLabel(elapsedSeconds))"
        case let .paused(elapsedSeconds):
            return "Paused · \(Self.clockLabel(elapsedSeconds))"
        case let .finalizing(progress):
            if progress >= 1 {
                return "Ready to review"
            }
            return "Finalizing · \(Int((progress * 100).rounded()))%"
        case let .saved(durationSeconds):
            return "Saved · \(Self.durationLabel(durationSeconds))"
        case let .recovered(durationSeconds):
            return "Recovered · \(Self.durationLabel(durationSeconds))"
        case .failed:
            return "Failed"
        }
    }

    public var elapsedSeconds: Int? {
        switch self {
        case let .recording(elapsedSeconds),
             let .paused(elapsedSeconds),
             let .saved(elapsedSeconds),
             let .recovered(elapsedSeconds):
            return elapsedSeconds
        case .preparing, .finalizing, .failed:
            return nil
        }
    }

    public var finalizingProgress: Double? {
        if case let .finalizing(progress) = self {
            return progress
        }
        return nil
    }

    private static func clockLabel(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let remainingSeconds = max(0, seconds) % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private static func durationLabel(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        return "\(minutes) min"
    }
}

public struct TranscriptSentence: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startTime: Int
    public var endTime: Int
    public var text: String
    public var translation: String
    public var confidence: TranscriptConfidence

    public init(
        id: UUID = UUID(),
        startTime: Int,
        endTime: Int,
        text: String,
        translation: String,
        confidence: TranscriptConfidence
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.translation = translation
        self.confidence = confidence
    }
}

public enum TranscriptConfidence: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

public struct TopicNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var startTime: Int
    public var endTime: Int?
    public var summary: String
    public var keyPoints: [String]
    public var questions: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        startTime: Int,
        endTime: Int?,
        summary: String,
        keyPoints: [String],
        questions: [String]
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.summary = summary
        self.keyPoints = keyPoints
        self.questions = questions
    }
}
