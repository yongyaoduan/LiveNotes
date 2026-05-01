import Foundation

public struct MarkdownExporter: Sendable {
    public init() {}

    public func export(_ session: RecordingSession) -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("Status: \(session.status.label)")
        lines.append("")

        if !session.transcript.isEmpty {
            lines.append("## Transcript")
            lines.append("")

            for sentence in TranscriptUtteranceSegmenter.segment(
                session.transcript,
                translationMode: .preserveMergedTranslations
            ) {
                lines.append("[\(timeLabel(sentence.startTime))] \(sentence.text)")
                if !sentence.translation.isEmpty {
                    lines.append(sentence.translation)
                } else {
                    lines.append("Translation unavailable.")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func timeLabel(_ seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

struct ExportDirectoryHistory {
    private let defaults: UserDefaults
    private let key = "app.livenotes.export.lastDirectory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func directory(defaultDirectory: URL) -> URL {
        guard let path = defaults.string(forKey: key),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func rememberExportURL(_ url: URL) {
        defaults.set(url.deletingLastPathComponent().path, forKey: key)
    }
}
