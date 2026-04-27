import Foundation
import CryptoKit

public enum LocalRuntime: String, Codable, Equatable, Sendable {
    case localMLX
}

public enum TranslationDirection: String, Codable, Equatable, Sendable {
    case englishToChinese

    public static let supported: [TranslationDirection] = [.englishToChinese]

    public static func supports(source: String, target: String) -> Bool {
        source.lowercased() == "en" && target.lowercased() == "zh"
    }
}

public struct LocalModelReference: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct LocalTranslationModelReference: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var direction: TranslationDirection

    public init(
        id: String,
        displayName: String,
        direction: TranslationDirection
    ) {
        self.id = id
        self.displayName = displayName
        self.direction = direction
    }
}

public struct LocalModelConfiguration: Codable, Equatable, Sendable {
    public var runtime: LocalRuntime
    public var transcription: LocalModelReference
    public var summarization: LocalModelReference
    public var translation: LocalTranslationModelReference

    public init(
        runtime: LocalRuntime,
        transcription: LocalModelReference,
        summarization: LocalModelReference,
        translation: LocalTranslationModelReference
    ) {
        self.runtime = runtime
        self.transcription = transcription
        self.summarization = summarization
        self.translation = translation
    }

    public var usesRemoteProvider: Bool {
        false
    }

    public static let `default` = LocalModelConfiguration(
        runtime: .localMLX,
        transcription: LocalModelReference(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo"
        ),
        summarization: LocalModelReference(
            id: "qwen3-4b-4bit",
            displayName: "Qwen3 4B 4-bit"
        ),
        translation: LocalTranslationModelReference(
            id: "qwen3-4b-4bit",
            displayName: "Qwen3 4B 4-bit EN-ZH",
            direction: .englishToChinese
        )
    )
}

public struct LocalModelArtifactRequirement: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int?
    public var sha256: String?
    public var kind: String

    public init(
        path: String,
        size: Int? = nil,
        sha256: String? = nil,
        kind: String = "file"
    ) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.kind = kind
    }
}

public struct LocalModelBundleManifest: Codable, Equatable, Sendable {
    public var artifacts: [LocalModelArtifactRequirement]

    public init(artifacts: [LocalModelArtifactRequirement]) {
        self.artifacts = artifacts
    }

    public var requiredArtifactPaths: [String] {
        artifacts.map(\.path)
    }

    public static let `default` = LocalModelBundleManifest(
        artifacts: [
            LocalModelArtifactRequirement(path: "models/whisper-large-v3-turbo/config.json", size: 268, sha256: "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379", kind: "json"),
            LocalModelArtifactRequirement(path: "models/whisper-large-v3-turbo/weights.safetensors", size: 1_613_977_612, sha256: "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6", kind: "binary"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/config.json", size: 937, sha256: "b5efdcf3b0035a3638e7228dad4d85f5c4a23f156eb7cdb0b44c8366a5d34d9b", kind: "json"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/added_tokens.json", size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680", kind: "json"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5", kind: "text"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/tokenizer.json", size: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", kind: "json"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/tokenizer_config.json", size: 9_706, sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0", kind: "json"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", kind: "json"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", kind: "json"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/model.safetensors", size: 2_263_022_529, sha256: "e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d", kind: "binary"),
            LocalModelArtifactRequirement(path: "models/qwen3-4b/model.safetensors.index.json", size: 63_924, sha256: "f7825defe5865d179c3b593173d37056be5f202dcb7153985cf74e75ecf1628b", kind: "safetensorsIndex")
        ]
    )
}

public struct LocalModelBundleValidation: Equatable, Sendable {
    public var missingArtifacts: [String]

    public init(missingArtifacts: [String]) {
        self.missingArtifacts = missingArtifacts
    }

    public var isReady: Bool {
        missingArtifacts.isEmpty
    }

    public var userFacingStatus: String {
        isReady ? "Ready" : "Missing Files"
    }
}

public struct LocalModelBundleReadiness: Equatable, Sendable {
    public var validation: LocalModelBundleValidation
    public var readyRoot: URL?

    public init(validation: LocalModelBundleValidation, readyRoot: URL?) {
        self.validation = validation
        self.readyRoot = readyRoot
    }

    public var userFacingStatus: String {
        validation.userFacingStatus
    }
}

public struct LocalModelBundleVerifier: Sendable {
    public var validateChecksums: Bool

    public init(validateChecksums: Bool = true) {
        self.validateChecksums = validateChecksums
    }

    public func validate(
        root: URL,
        manifest: LocalModelBundleManifest
    ) -> LocalModelBundleValidation {
        let missingArtifacts = manifest.artifacts.filter { artifact in
            let url = root.appendingPathComponent(artifact.path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return true
            }
            guard size.intValue > 0 else { return true }
            if let expectedSize = artifact.size, size.intValue != expectedSize {
                return true
            }
            if validateChecksums, let expectedSHA256 = artifact.sha256, sha256(url: url) != expectedSHA256 {
                return true
            }
            if artifact.kind == "json" && !isValidJSON(url: url) {
                return true
            }
            if artifact.kind == "safetensorsIndex" && !isValidSafetensorsIndex(url: url) {
                return true
            }
            return false
        }.map(\.path)
        return LocalModelBundleValidation(missingArtifacts: missingArtifacts)
    }

    private func isValidJSON(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func isValidSafetensorsIndex(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = payload["weight_map"] as? [String: String],
              !weightMap.isEmpty else {
            return false
        }
        let directory = url.deletingLastPathComponent()
        return Set(weightMap.values).allSatisfy { shard in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(shard).path)
        }
    }

    private func sha256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher
            .finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct LocalModelBundleLocator {
    public static let artifactsDirectoryName = "LiveNotesArtifacts"

    public init() {}

    public func applicationSupportArtifactsURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("LiveNotes", isDirectory: true)
            .appendingPathComponent(Self.artifactsDirectoryName, isDirectory: true)
    }

    public func candidateRoots(
        bundleResourceURL: URL?,
        applicationSupportArtifactsURL: URL
    ) -> [URL] {
        var roots: [URL] = []
        if let bundleResourceURL {
            roots.append(
                bundleResourceURL.appendingPathComponent(
                    Self.artifactsDirectoryName,
                    isDirectory: true
                )
            )
        }
        roots.append(applicationSupportArtifactsURL)
        return roots
    }

    public func firstReadyRoot(
        bundleResourceURL: URL?,
        applicationSupportArtifactsURL: URL,
        manifest: LocalModelBundleManifest = .default
    ) -> URL? {
        resolveFirstReadyRoot(
            bundleResourceURL: bundleResourceURL,
            applicationSupportArtifactsURL: applicationSupportArtifactsURL,
            manifest: manifest
        )
        .readyRoot
    }

    public func validateFirstReadyRoot(
        bundleResourceURL: URL?,
        applicationSupportArtifactsURL: URL,
        manifest: LocalModelBundleManifest = .default,
        verifier: LocalModelBundleVerifier = LocalModelBundleVerifier()
    ) -> LocalModelBundleValidation {
        resolveFirstReadyRoot(
            bundleResourceURL: bundleResourceURL,
            applicationSupportArtifactsURL: applicationSupportArtifactsURL,
            manifest: manifest,
            verifier: verifier
        )
        .validation
    }

    public func resolveFirstReadyRoot(
        bundleResourceURL: URL?,
        applicationSupportArtifactsURL: URL,
        manifest: LocalModelBundleManifest = .default,
        verifier: LocalModelBundleVerifier = LocalModelBundleVerifier()
    ) -> LocalModelBundleReadiness {
        let roots = candidateRoots(
            bundleResourceURL: bundleResourceURL,
            applicationSupportArtifactsURL: applicationSupportArtifactsURL
        )
        var firstValidation: LocalModelBundleValidation?
        for root in roots {
            let validation = verifier.validate(root: root, manifest: manifest)
            if validation.isReady {
                return LocalModelBundleReadiness(validation: validation, readyRoot: root)
            }
            if firstValidation == nil {
                firstValidation = validation
            }
        }
        return LocalModelBundleReadiness(
            validation: firstValidation ?? LocalModelBundleValidation(
                missingArtifacts: manifest.requiredArtifactPaths
            ),
            readyRoot: nil
        )
    }
}
