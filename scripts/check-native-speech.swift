import Foundation
import Darwin
import Speech

// Report the runner's real SpeechAnalyzer capability before attempting UI tests.
// An unavailable runtime is a failing prerequisite, never a simulated ASR pass.
@main struct CheckNativeSpeech {
    static func main() async {
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        let locales = await SpeechTranscriber.supportedLocales
        print("Supported locales: \(locales.map(\.identifier).sorted())")
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        print("English assets: \(await AssetInventory.status(forModules: [transcriber]))")
        guard SpeechTranscriber.isAvailable else {
            fputs("SpeechTranscriber is unavailable on this runner. Use a supported Mac for native speech validation.\n", stderr)
            exit(1)
        }
    }
}
