import Foundation

/// The canonical Whisper model identifiers WhisperKit publishes CoreML artifacts for.
///
/// No `large-v1`: `argmaxinc/whisperkit-coreml` does not publish it.
enum WhisperModelID: String, CaseIterable, Identifiable, Sendable {
    case tinyEn = "tiny.en"
    case tiny = "tiny"
    case baseEn = "base.en"
    case base = "base"
    case smallEn = "small.en"
    case small = "small"
    case mediumEn = "medium.en"
    case medium = "medium"
    case largeV2 = "large-v2"
    case largeV3 = "large-v3"
    case turbo = "turbo"

    var id: String { rawValue }
}

/// Static metadata describing one Whisper model. `WhisperModelStore` verifies file checksums
/// at download time.
struct WhisperModelDescriptor: Identifiable, Equatable, Sendable {
    let id: WhisperModelID
    /// Human-readable name suitable for UI (e.g. a model picker).
    let displayName: String
    /// The WhisperKit CoreML repo's HF subfolder name for this model
    /// (e.g. "openai_whisper-small.en"), as published under `argmaxinc/whisperkit-coreml`.
    let runtimeArtifact: String
    /// Whether this checkpoint was trained English-only (the `.en` variants).
    let englishOnly: Bool
    /// The `openai/whisper-*` repo the tokenizer files come from. Must match WhisperKit's
    /// `ModelUtilities.tokenizerNameForVariant`, which maps `turbo` to `whisper-large-v3`.
    let tokenizerRepo: String
}

/// Pure metadata catalog for the Whisper models Relay's WhisperKit backend can offer. No network
/// access, no inference, no backend wiring -- just the static facts a model picker and
/// `WhisperModelStore` need to identify each model.
enum WhisperModelCatalog {
    static func descriptor(for id: WhisperModelID) -> WhisperModelDescriptor {
        descriptorsByID[id]!
    }

    private static let descriptorsByID: [WhisperModelID: WhisperModelDescriptor] = {
        var map = [WhisperModelID: WhisperModelDescriptor]()
        for descriptor in allDescriptors {
            map[descriptor.id] = descriptor
        }
        return map
    }()

    private static let allDescriptors: [WhisperModelDescriptor] = [
        WhisperModelDescriptor(
            id: .tinyEn,
            displayName: "Tiny (English)",
            runtimeArtifact: "openai_whisper-tiny.en",
            englishOnly: true,
            tokenizerRepo: "openai/whisper-tiny.en"
        ),
        WhisperModelDescriptor(
            id: .tiny,
            displayName: "Tiny",
            runtimeArtifact: "openai_whisper-tiny",
            englishOnly: false,
            tokenizerRepo: "openai/whisper-tiny"
        ),
        WhisperModelDescriptor(
            id: .baseEn,
            displayName: "Base (English)",
            runtimeArtifact: "openai_whisper-base.en",
            englishOnly: true,
            tokenizerRepo: "openai/whisper-base.en"
        ),
        WhisperModelDescriptor(
            id: .base,
            displayName: "Base",
            runtimeArtifact: "openai_whisper-base",
            englishOnly: false,
            tokenizerRepo: "openai/whisper-base"
        ),
        WhisperModelDescriptor(
            id: .smallEn,
            displayName: "Small (English)",
            runtimeArtifact: "openai_whisper-small.en",
            englishOnly: true,
            tokenizerRepo: "openai/whisper-small.en"
        ),
        WhisperModelDescriptor(
            id: .small,
            displayName: "Small",
            runtimeArtifact: "openai_whisper-small",
            englishOnly: false,
            tokenizerRepo: "openai/whisper-small"
        ),
        WhisperModelDescriptor(
            id: .mediumEn,
            displayName: "Medium (English)",
            runtimeArtifact: "openai_whisper-medium.en",
            englishOnly: true,
            tokenizerRepo: "openai/whisper-medium.en"
        ),
        WhisperModelDescriptor(
            id: .medium,
            displayName: "Medium",
            runtimeArtifact: "openai_whisper-medium",
            englishOnly: false,
            tokenizerRepo: "openai/whisper-medium"
        ),
        WhisperModelDescriptor(
            id: .largeV2,
            displayName: "Large v2",
            runtimeArtifact: "openai_whisper-large-v2",
            englishOnly: false,
            tokenizerRepo: "openai/whisper-large-v2"
        ),
        WhisperModelDescriptor(
            id: .largeV3,
            displayName: "Large v3",
            runtimeArtifact: "openai_whisper-large-v3",
            englishOnly: false,
            tokenizerRepo: "openai/whisper-large-v3"
        ),
        WhisperModelDescriptor(
            id: .turbo,
            displayName: "Turbo",
            runtimeArtifact: "openai_whisper-large-v3_turbo",
            englishOnly: false,
            tokenizerRepo: "openai/whisper-large-v3"
        ),
    ]
}
