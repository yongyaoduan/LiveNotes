import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Local model bundle")
struct LocalModelBundleTests {
    @Test("default configuration uses local MLX models without remote providers")
    func defaultConfigurationUsesLocalModels() {
        let configuration = LocalModelConfiguration.default

        #expect(configuration.runtime == .mlxSwift)
        #expect(configuration.transcription.id == "whisper-medium")
        #expect(configuration.summarization.id == "qwen3-4b")
        #expect(configuration.translation.id == "qwen3-1.7b")
        #expect(configuration.translation.direction == .englishToChinese)
        #expect(configuration.usesRemoteProvider == false)
    }

    @Test("translation supports English to Chinese only")
    func translationSupportsEnglishToChineseOnly() {
        #expect(TranslationDirection.supported == [.englishToChinese])
        #expect(TranslationDirection.supports(source: "en", target: "zh") == true)
        #expect(TranslationDirection.supports(source: "zh", target: "en") == false)
        #expect(TranslationDirection.supports(source: "en", target: "ja") == false)
    }

    @Test("bundle verifier reports every missing required artifact")
    func bundleVerifierReportsMissingArtifacts() throws {
        let root = try temporaryDirectory()

        let result = LocalModelBundleVerifier().validate(
            root: root,
            manifest: .default
        )

        #expect(result.isReady == false)
        #expect(result.userFacingStatus == "Missing Files")
        #expect(result.missingArtifacts.contains("models/whisper-medium/weights.npz"))
        #expect(result.missingArtifacts.contains("models/qwen3-4b/tokenizer.json"))
        #expect(result.missingArtifacts.contains("models/qwen3-1.7b/model.safetensors"))
    }

    @Test("bundle verifier accepts a complete local artifact tree")
    func bundleVerifierAcceptsCompleteTree() throws {
        let root = try temporaryDirectory()
        for path in LocalModelBundleManifest.default.requiredArtifactPaths {
            let fileURL = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: fileURL)
        }

        let result = LocalModelBundleVerifier().validate(
            root: root,
            manifest: .default
        )

        #expect(result.isReady == true)
        #expect(result.userFacingStatus == "Ready")
        #expect(result.missingArtifacts.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
