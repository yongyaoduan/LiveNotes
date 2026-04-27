import Foundation
import Testing
@testable import LiveNotesCore

@Suite("Local model bundle")
struct LocalModelBundleTests {
    @Test("default configuration uses local MLX models without remote providers")
    func defaultConfigurationUsesLocalModels() {
        let configuration = LocalModelConfiguration.default

        #expect(configuration.runtime == .localMLX)
        #expect(configuration.transcription.id == "whisper-large-v3-turbo")
        #expect(configuration.summarization.id == "qwen3-4b-4bit")
        #expect(configuration.translation.id == "qwen3-4b-4bit")
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
        #expect(result.missingArtifacts.contains("models/whisper-large-v3-turbo/weights.safetensors"))
        #expect(result.missingArtifacts.contains("models/qwen3-4b/tokenizer.json"))
        #expect(result.missingArtifacts.contains("models/qwen3-4b/model.safetensors"))
    }

    @Test("bundle verifier accepts a complete local artifact tree")
    func bundleVerifierAcceptsCompleteTree() throws {
        let root = try temporaryDirectory()
        let manifest = fixtureManifest()
        try writeFixtureArtifacts(to: root, manifest: manifest)

        let result = LocalModelBundleVerifier().validate(
            root: root,
            manifest: manifest
        )

        #expect(result.isReady == true)
        #expect(result.userFacingStatus == "Ready")
        #expect(result.missingArtifacts.isEmpty)
    }

    @Test("bundle verifier rejects corrupt non-empty artifacts")
    func bundleVerifierRejectsCorruptArtifacts() throws {
        let root = try temporaryDirectory()
        let manifest = LocalModelBundleManifest(
            artifacts: [
                LocalModelArtifactRequirement(
                    path: "models/test/config.json",
                    size: 8,
                    kind: "json"
                )
            ]
        )
        let fileURL = root.appendingPathComponent("models/test/config.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture\n".utf8).write(to: fileURL)

        let result = LocalModelBundleVerifier().validate(
            root: root,
            manifest: manifest
        )

        #expect(result.isReady == false)
        #expect(result.missingArtifacts == ["models/test/config.json"])
    }

    @Test("bundle verifier checks hashes by default for runtime readiness")
    func bundleVerifierChecksHashesByDefaultForRuntimeReadiness() throws {
        let root = try temporaryDirectory()
        let manifest = LocalModelBundleManifest(
            artifacts: [
                LocalModelArtifactRequirement(
                    path: "models/test/model.safetensors",
                    size: Data("fixed-size-bad".utf8).count,
                    sha256: "d386fb6e3164251f076ca47cb55306abc582fcfe3def684611c3466c2ca99c0e",
                    kind: "binary"
                )
            ]
        )
        let fileURL = root.appendingPathComponent("models/test/model.safetensors")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixed-size-bad".utf8).write(to: fileURL)

        let result = LocalModelBundleVerifier().validate(
            root: root,
            manifest: manifest
        )

        #expect(result.isReady == false)
        #expect(result.missingArtifacts == ["models/test/model.safetensors"])
    }

    @Test("strict bundle verifier rejects same-size artifact with wrong hash")
    func strictBundleVerifierRejectsSameSizeWrongHash() throws {
        let root = try temporaryDirectory()
        let manifest = LocalModelBundleManifest(
            artifacts: [
                LocalModelArtifactRequirement(
                    path: "models/test/model.safetensors",
                    size: Data("fixed-size-bad".utf8).count,
                    sha256: "d386fb6e3164251f076ca47cb55306abc582fcfe3def684611c3466c2ca99c0e",
                    kind: "binary"
                )
            ]
        )
        let fileURL = root.appendingPathComponent("models/test/model.safetensors")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixed-size-bad".utf8).write(to: fileURL)

        let result = LocalModelBundleVerifier(validateChecksums: true).validate(
            root: root,
            manifest: manifest
        )

        #expect(result.isReady == false)
        #expect(result.missingArtifacts == ["models/test/model.safetensors"])
    }

    @Test("bundle locator accepts Homebrew application support artifacts")
    func bundleLocatorAcceptsApplicationSupportArtifacts() throws {
        let applicationSupportRoot = try temporaryDirectory()
        let manifest = fixtureManifest()
        try writeFixtureArtifacts(to: applicationSupportRoot, manifest: manifest)

        let result = LocalModelBundleLocator().validateFirstReadyRoot(
            bundleResourceURL: nil,
            applicationSupportArtifactsURL: applicationSupportRoot,
            manifest: manifest
        )

        #expect(result.isReady == true)
        #expect(result.userFacingStatus == "Ready")
    }

    @Test("bundle locator prefers any ready local root")
    func bundleLocatorPrefersAnyReadyLocalRoot() throws {
        let missingBundleResourceRoot = try temporaryDirectory()
        let externalRoot = try temporaryDirectory()
        let manifest = fixtureManifest()
        try writeFixtureArtifacts(to: externalRoot, manifest: manifest)

        let result = LocalModelBundleLocator().validateFirstReadyRoot(
            bundleResourceURL: missingBundleResourceRoot,
            applicationSupportArtifactsURL: externalRoot,
            manifest: manifest
        )

        #expect(result.isReady == true)
        #expect(result.missingArtifacts.isEmpty)
    }

    @Test("bundle locator returns ready root with validation")
    func bundleLocatorReturnsReadyRootWithValidation() throws {
        let missingBundleResourceRoot = try temporaryDirectory()
        let applicationSupportRoot = try temporaryDirectory()
        let manifest = fixtureManifest()
        try writeFixtureArtifacts(to: applicationSupportRoot, manifest: manifest)

        let result = LocalModelBundleLocator().resolveFirstReadyRoot(
            bundleResourceURL: missingBundleResourceRoot,
            applicationSupportArtifactsURL: applicationSupportRoot,
            manifest: manifest
        )

        #expect(result.validation.isReady == true)
        #expect(result.readyRoot == applicationSupportRoot)
        #expect(result.userFacingStatus == "Ready")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixtureManifest() -> LocalModelBundleManifest {
        LocalModelBundleManifest(
            artifacts: [
                LocalModelArtifactRequirement(
                    path: "models/test/config.json",
                    size: Data("{\"model\":\"fixture\"}".utf8).count,
                    sha256: "0598e1374701ed810b063d222dab05fb508ce02a4d55c2bdf35b9eca0af87fa4",
                    kind: "json"
                ),
                LocalModelArtifactRequirement(
                    path: "models/test/model.safetensors",
                    size: Data("binary-fixture".utf8).count,
                    sha256: "d386fb6e3164251f076ca47cb55306abc582fcfe3def684611c3466c2ca99c0e",
                    kind: "binary"
                ),
                LocalModelArtifactRequirement(
                    path: "models/test/model.safetensors.index.json",
                    size: Data("{\"weight_map\":{\"layer\":\"model.safetensors\"}}".utf8).count,
                    sha256: "15b2f9a47fa121b4f77e24fc041be28bf21f1e8fc9bb5f12a72d65d2910b8995",
                    kind: "safetensorsIndex"
                )
            ]
        )
    }

    private func writeFixtureArtifacts(
        to root: URL,
        manifest: LocalModelBundleManifest
    ) throws {
        for artifact in manifest.artifacts {
            let fileURL = root.appendingPathComponent(artifact.path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data: Data
            switch artifact.path {
            case let path where path.hasSuffix("config.json"):
                data = Data("{\"model\":\"fixture\"}".utf8)
            case let path where path.hasSuffix("model.safetensors.index.json"):
                data = Data("{\"weight_map\":{\"layer\":\"model.safetensors\"}}".utf8)
            default:
                data = Data("binary-fixture".utf8)
            }
            try data.write(to: fileURL)
        }
    }
}
