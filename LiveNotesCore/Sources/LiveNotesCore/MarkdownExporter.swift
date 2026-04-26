import Foundation

public struct MarkdownExporter: Sendable {
    public init() {}

    public func export(_ session: RecordingSession) -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("Status: \(session.status.label)")
        lines.append("")

        if !session.topics.isEmpty {
            lines.append("## Topics")
            lines.append("")

            for topic in session.topics {
                lines.append("## \(topic.title)")
                lines.append("")
                lines.append(timeRangeLabel(start: topic.startTime, end: topic.endTime))
                lines.append("")

                if !topic.summary.isEmpty {
                    lines.append(topic.summary)
                    lines.append("")
                }

                if !topic.keyPoints.isEmpty {
                    lines.append("### Key Points")
                    for point in topic.keyPoints {
                        lines.append("- \(point)")
                    }
                    lines.append("")
                }

                if !topic.questions.isEmpty {
                    lines.append("### Questions")
                    for question in topic.questions {
                        lines.append("- \(question)")
                    }
                    lines.append("")
                }
            }
        }

        if !session.transcript.isEmpty {
            lines.append("### Transcript")
            lines.append("")

            for sentence in session.transcript {
                lines.append("[\(timeLabel(sentence.startTime))] \(sentence.text)")
                if !sentence.translation.isEmpty {
                    lines.append(sentence.translation)
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func timeRangeLabel(start: Int, end: Int?) -> String {
        guard let end else {
            return "\(timeLabel(start)) - now"
        }
        return "\(timeLabel(start)) - \(timeLabel(end))"
    }

    private func timeLabel(_ seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
