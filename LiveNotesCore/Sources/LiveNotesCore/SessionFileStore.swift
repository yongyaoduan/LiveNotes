import Foundation

public struct SessionFileStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public var libraryDirectoryURL: URL {
        url.deletingLastPathComponent()
    }

    public func localFileURL(relativePath: String) -> URL {
        libraryDirectoryURL.appendingPathComponent(relativePath)
    }

    public func load() throws -> [RecordingSession] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([RecordingSession].self, from: data)
    }

    public func loadPreservingCorruptFile() -> SessionFileLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SessionFileLoadResult(sessions: [], recovery: nil)
        }
        do {
            return SessionFileLoadResult(sessions: try load(), recovery: nil)
        } catch {
            let backupURL = corruptBackupURL()
            do {
                try FileManager.default.moveItem(at: url, to: backupURL)
                return SessionFileLoadResult(
                    sessions: [],
                    recovery: SessionFileLoadRecovery(
                        backupURL: backupURL,
                        message: "Library file could not be read and was preserved."
                    )
                )
            } catch {
                return SessionFileLoadResult(
                    sessions: [],
                    recovery: SessionFileLoadRecovery(
                        backupURL: url,
                        message: "Library file could not be read."
                    )
                )
            }
        }
    }

    public func save(_ sessions: [RecordingSession]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(sessions)
        try data.write(to: url, options: [.atomic])
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func corruptBackupURL() -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return url.deletingLastPathComponent()
            .appendingPathComponent("sessions.corrupt-\(stamp).json")
    }
}

public struct SessionFileLoadResult: Equatable, Sendable {
    public var sessions: [RecordingSession]
    public var recovery: SessionFileLoadRecovery?

    public init(
        sessions: [RecordingSession],
        recovery: SessionFileLoadRecovery?
    ) {
        self.sessions = sessions
        self.recovery = recovery
    }
}

public struct SessionFileLoadRecovery: Equatable, Sendable {
    public var backupURL: URL
    public var message: String

    public init(backupURL: URL, message: String) {
        self.backupURL = backupURL
        self.message = message
    }
}
