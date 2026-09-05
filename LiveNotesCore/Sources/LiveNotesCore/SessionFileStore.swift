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

    public func exportSnapshot(_ session: RecordingSession, to markdownURL: URL) throws {
        let fileManager = FileManager.default
        let audioSourceURL = session.audioFileName.map { localFileURL(relativePath: $0) }
        if let audioSourceURL, !fileManager.fileExists(atPath: audioSourceURL.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        let directoryURL = markdownURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let stagingURL = directoryURL.appendingPathComponent(".livenotes-export-\(UUID().uuidString)")
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        var removeStagingDirectory = true
        defer {
            if removeStagingDirectory {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        let stagedMarkdownURL = stagingURL.appendingPathComponent("transcript.md")
        try MarkdownExporter().export(session).write(to: stagedMarkdownURL, atomically: true, encoding: .utf8)
        var files = [(staged: stagedMarkdownURL, destination: markdownURL)]
        if let audioSourceURL {
            let audioExtension = audioSourceURL.pathExtension.isEmpty ? "m4a" : audioSourceURL.pathExtension
            let audioDestinationURL = markdownURL.deletingPathExtension().appendingPathExtension(audioExtension)
            if audioSourceURL.resolvingSymlinksInPath() != audioDestinationURL.resolvingSymlinksInPath() {
                let stagedAudioURL = stagingURL.appendingPathComponent("recording.\(audioExtension)")
                try fileManager.copyItem(at: audioSourceURL, to: stagedAudioURL)
                files.append((stagedAudioURL, audioDestinationURL))
            }
        }
        for file in files {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: file.destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.destination.path])
            }
        }
        var publishedFiles: [(destination: URL, backup: URL?)] = []
        do {
            for (index, file) in files.enumerated() {
                var backupURL: URL?
                if fileManager.fileExists(atPath: file.destination.path) {
                    let candidate = stagingURL.appendingPathComponent("previous-\(index)")
                    try fileManager.moveItem(at: file.destination, to: candidate)
                    backupURL = candidate
                }
                publishedFiles.append((file.destination, backupURL))
                try fileManager.moveItem(at: file.staged, to: file.destination)
            }
        } catch {
            for file in publishedFiles.reversed() {
                do {
                    if fileManager.fileExists(atPath: file.destination.path) {
                        try fileManager.removeItem(at: file.destination)
                    }
                    if let backupURL = file.backup {
                        try fileManager.moveItem(at: backupURL, to: file.destination)
                    }
                } catch {
                    removeStagingDirectory = false
                }
            }
            throw error
        }
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
