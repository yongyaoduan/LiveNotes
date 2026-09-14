import Foundation
import Speech

// Report the runner's real SpeechAnalyzer capability before attempting UI tests.
// An unavailable runtime is a failing prerequisite, never a simulated ASR pass.
@main struct CheckNativeSpeech {
    static func main() async throws {
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        let locales = await SpeechTranscriber.supportedLocales
        print("Supported locales: \(locales.map(\.identifier).sorted())")
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        print("English assets: \(await AssetInventory.status(forModules: [transcriber]))")
        guard SpeechTranscriber.isAvailable else {
            throw NSError(domain: "LiveNotes.NativeSpeechPrerequisite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber is unavailable on this runner."])
        }
    }
}
