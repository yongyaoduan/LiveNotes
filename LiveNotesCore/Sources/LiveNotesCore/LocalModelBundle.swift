import Foundation

public enum LocalRuntime: String, Codable, Equatable, Sendable {
    case mlxSwift
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
        runtime: .mlxSwift,
        transcription: LocalModelReference(
            id: "whisper-medium",
            displayName: "Whisper Medium"
        ),
        summarization: LocalModelReference(
            id: "qwen3-4b",
            displayName: "Qwen3 4B"
        ),
        translation: LocalTranslationModelReference(
            id: "qwen3-1.7b",
            displayName: "Qwen3 1.7B EN-ZH",
            direction: .englishToChinese
        )
    )
}

public struct LocalModelBundleManifest: Codable, Equatable, Sendable {
    public var requiredArtifactPaths: [String]

    public init(requiredArtifactPaths: [String]) {
        self.requiredArtifactPaths = requiredArtifactPaths
    }

    public static let `default` = LocalModelBundleManifest(
        requiredArtifactPaths: [
            "models/whisper-medium/config.json",
            "models/whisper-medium/weights.npz",
            "models/qwen3-4b/config.json",
            "models/qwen3-4b/added_tokens.json",
            "models/qwen3-4b/merges.txt",
            "models/qwen3-4b/tokenizer.json",
            "models/qwen3-4b/tokenizer_config.json",
            "models/qwen3-4b/special_tokens_map.json",
            "models/qwen3-4b/vocab.json",
            "models/qwen3-4b/model.safetensors",
            "models/qwen3-4b/model.safetensors.index.json",
            "models/qwen3-1.7b/config.json",
            "models/qwen3-1.7b/added_tokens.json",
            "models/qwen3-1.7b/merges.txt",
            "models/qwen3-1.7b/tokenizer.json",
            "models/qwen3-1.7b/tokenizer_config.json",
            "models/qwen3-1.7b/special_tokens_map.json",
            "models/qwen3-1.7b/vocab.json",
            "models/qwen3-1.7b/model.safetensors",
            "models/qwen3-1.7b/model.safetensors.index.json"
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

public struct LocalModelBundleVerifier: Sendable {
    public init() {}

    public func validate(
        root: URL,
        manifest: LocalModelBundleManifest
    ) -> LocalModelBundleValidation {
        let missingArtifacts = manifest.requiredArtifactPaths.filter { relativePath in
            let url = root.appendingPathComponent(relativePath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return true
            }
            return size.intValue == 0
        }
        return LocalModelBundleValidation(missingArtifacts: missingArtifacts)
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

    public func validateFirstReadyRoot(
        bundleResourceURL: URL?,
        applicationSupportArtifactsURL: URL,
        manifest: LocalModelBundleManifest = .default,
        verifier: LocalModelBundleVerifier = LocalModelBundleVerifier()
    ) -> LocalModelBundleValidation {
        let roots = candidateRoots(
            bundleResourceURL: bundleResourceURL,
            applicationSupportArtifactsURL: applicationSupportArtifactsURL
        )
        var firstValidation: LocalModelBundleValidation?
        for root in roots {
            let validation = verifier.validate(root: root, manifest: manifest)
            if validation.isReady {
                return validation
            }
            if firstValidation == nil {
                firstValidation = validation
            }
        }
        return firstValidation ?? LocalModelBundleValidation(
            missingArtifacts: manifest.requiredArtifactPaths
        )
    }
}
