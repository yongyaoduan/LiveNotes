// Compile with the production core sources; see docs/validation-2026-09-14.md.
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

struct CapturedResult: Codable {
    struct Fragment: Codable { var text: String; var startTime: Double; var endTime: Double }
    var text: String
    var startTime: Double
    var endTime: Double
    var isFinal: Bool
    var resultsFinalizationTime: Double?
    var fragments: [Fragment]
    var receivedAt: Double
    var update: SpeechAnalyzerTranscriptUpdate {
        var value = SpeechAnalyzerTranscriptUpdate(text: text, startTime: startTime, endTime: endTime,
            isFinal: isFinal, confidence: isFinal ? .high : .medium, resultsFinalizationTime: resultsFinalizationTime)
        value.fragments = fragments.map { .init(text: $0.text, startTime: $0.startTime, endTime: $0.endTime) }
        return value
    }
}

@main struct RealAudioBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["live", "replay"].contains(args[3]) else { fatalError("Usage: benchmark <audio.wav|events.json> <output-prefix> <live|replay>") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let store = SpeechAnalyzerTranscriptAssemblyStore()
        var captured: [CapturedResult] = []
        var snapshots: [[String: String]] = []
        if args[3] == "replay" {
            captured = try JSONDecoder().decode([CapturedResult].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            for record in captured {
                let events = await store.apply(record.update)
                let preview = events.compactMap { event -> String? in if case let .preview(text) = event { return text }; return nil }.last ?? ""
                snapshots.append(["preview": preview, "committed": await store.snapshot().map(\.text).joined(separator: " ")])
            }
        } else {
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
            let modules: [any SpeechModule] = [transcriber]
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) { try await request.downloadAndInstall() }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { fatalError("No format") }
            let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
            let pipe = SpeechAnalyzerInputPipe()
            let converter = SpeechAnalyzerLiveInputConverter(targetFormat: format)
            try await analyzer.prepareToAnalyze(in: format)
            let start = Date()
            let reader = Task { () throws -> ([CapturedResult], [[String: String]]) in
                var records: [CapturedResult] = []
                var views: [[String: String]] = []
                for try await result in transcriber.results {
                    let update = SpeechAnalyzerTranscriptUpdate(result: result)
                    records.append(CapturedResult(text: update.text, startTime: update.startTime, endTime: update.endTime,
                        isFinal: update.isFinal, resultsFinalizationTime: update.resultsFinalizationTime.flatMap { $0.isFinite ? $0 : nil },
                        fragments: update.fragments.map { .init(text: $0.text, startTime: $0.startTime, endTime: $0.endTime) }, receivedAt: Date().timeIntervalSince(start)))
                    let events = await store.apply(update)
                    let preview = events.compactMap { event -> String? in if case let .preview(text) = event { return text }; return nil }.last ?? ""
                    views.append(["preview": preview, "committed": await store.snapshot().map(\.text).joined(separator: " ")])
                }
                return (records, views)
            }
            let analysis = Task {
                _ = try await analyzer.analyzeSequence(pipe.stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
            let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
            var sent: Double = 0
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
                try file.read(into: buffer)
                guard let input = converter.input(from: buffer) else { fatalError("Conversion failed") }
                pipe.yield(input)
                sent += Double(buffer.frameLength) / file.processingFormat.sampleRate
                let delay = sent - Date().timeIntervalSince(start)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
            pipe.finish()
            try await analysis.value
            (captured, snapshots) = try await reader.value
        }
        _ = await store.finish()
        let transcript = await store.snapshot()
        try encoder.encode(captured).write(to: URL(fileURLWithPath: args[2] + "-events.json"))
        try encoder.encode(snapshots).write(to: URL(fileURLWithPath: args[2] + "-snapshots.json"))
        try encoder.encode(transcript).write(to: URL(fileURLWithPath: args[2] + "-transcript.json"))
        print("Results: \(captured.count), final results: \(captured.filter(\.isFinal).count), saved lines: \(transcript.count)")
    }
}
