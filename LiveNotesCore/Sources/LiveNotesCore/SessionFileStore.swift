import Foundation

public struct SessionFileStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [RecordingSession] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([RecordingSession].self, from: data)
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
}
