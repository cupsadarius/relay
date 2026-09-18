import Foundation

/// The canonical Whisper model identifiers WhisperKit publishes CoreML artifacts for.
///
/// This intentionally excludes `large-v1`: WhisperKit's CoreML mirror
/// (`argmaxinc/whisperkit-coreml`) does not publish a `large-v1` folder at all (confirmed by
/// direct Hugging Face tree API query -- see
/// docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md section 2).
/// `large-v1` exists only on whisper.cpp's ggml mirror, which Relay does not use.
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

/// Static metadata describing one Whisper model's identity and expected footprint.
///
/// There is deliberately **no** per-model checksum here: identity and approximate size only.
/// Per-file checksum verification against Hugging Face's LFS/blob `oid`s happens later, at
/// download time, in `WhisperModelStore` -- not as a static value baked into the catalog.
struct WhisperModelDescriptor: Identifiable, Equatable, Sendable {
    let id: WhisperModelID
    /// Human-readable name suitable for UI (e.g. a model picker).
    let displayName: String
    /// The OpenAI checkpoint this artifact was converted from (e.g. "large-v3-turbo").
    let upstreamCheckpoint: String
    /// The WhisperKit CoreML repo's HF subfolder name for this model
    /// (e.g. "openai_whisper-small.en"), as published under `argmaxinc/whisperkit-coreml`.
    let runtimeArtifact: String
    /// Whether this checkpoint was trained English-only (the `.en` variants).
    let englishOnly: Bool
    /// Approximate on-disk size of the downloaded `.mlmodelc` bundle, in bytes. Sourced from the
    /// feasibility spike's live Hugging Face tree API measurement (`.mlmodelc/**` plus top-level
    /// `config.json`/`generation_config.json` only -- `.mlpackage` source copies excluded).
    let approximateDiskBytes: Int64
    /// The `openai/whisper-*` Hugging Face repo WhisperKit's own
    /// `ModelUtilities.tokenizerNameForVariant` resolves a loaded model of this id to -- i.e. the
    /// repo `WhisperModelStore` must fetch `tokenizer.json`/`tokenizer_config.json` from so they
    /// land in the model's own folder (`WhisperKitEngine.load`'s `tokenizerFolder: modelFolder`
    /// then lets WhisperKit's local-first tokenizer search find them there, with no live Hub
    /// fetch). Verified against argmax-oss-swift 1.1.0's
    /// `Sources/WhisperKit/Utilities/ModelUtilities.swift` (`tokenizerNameForVariant`), not
    /// guessed from `runtimeArtifact`/`upstreamCheckpoint` -- see
    /// `WhisperModelCatalogTests.testTokenizerRepoMatchesVerifiedWhisperKitMapping` for why
    /// `turbo` maps to `openai/whisper-large-v3` rather than a `-turbo`-named repo.
    let tokenizerRepo: String
}

/// Pure metadata catalog for the Whisper models Relay's WhisperKit backend can offer. No network
/// access, no inference, no backend wiring -- just the static facts a model picker and
/// `WhisperModelStore` need to identify and size each model.
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
            upstreamCheckpoint: "tiny.en",
            runtimeArtifact: "openai_whisper-tiny.en",
            englishOnly: true,
            approximateDiskBytes: 76_650_906,
            tokenizerRepo: "openai/whisper-tiny.en"
        ),
        WhisperModelDescriptor(
            id: .tiny,
            displayName: "Tiny",
            upstreamCheckpoint: "tiny",
            runtimeArtifact: "openai_whisper-tiny",
            englishOnly: false,
            approximateDiskBytes: 76_650_906,
            tokenizerRepo: "openai/whisper-tiny"
        ),
        WhisperModelDescriptor(
            id: .baseEn,
            displayName: "Base (English)",
            upstreamCheckpoint: "base.en",
            runtimeArtifact: "openai_whisper-base.en",
            englishOnly: true,
            approximateDiskBytes: 146_695_782,
            tokenizerRepo: "openai/whisper-base.en"
        ),
        WhisperModelDescriptor(
            id: .base,
            displayName: "Base",
            upstreamCheckpoint: "base",
            runtimeArtifact: "openai_whisper-base",
            englishOnly: false,
            approximateDiskBytes: 146_695_782,
            tokenizerRepo: "openai/whisper-base"
        ),
        WhisperModelDescriptor(
            id: .smallEn,
            displayName: "Small (English)",
            upstreamCheckpoint: "small.en",
            runtimeArtifact: "openai_whisper-small.en",
            englishOnly: true,
            approximateDiskBytes: 486_539_264,
            tokenizerRepo: "openai/whisper-small.en"
        ),
        WhisperModelDescriptor(
            id: .small,
            displayName: "Small",
            upstreamCheckpoint: "small",
            runtimeArtifact: "openai_whisper-small",
            englishOnly: false,
            approximateDiskBytes: 486_539_264,
            tokenizerRepo: "openai/whisper-small"
        ),
        WhisperModelDescriptor(
            id: .mediumEn,
            displayName: "Medium (English)",
            upstreamCheckpoint: "medium.en",
            runtimeArtifact: "openai_whisper-medium.en",
            englishOnly: true,
            approximateDiskBytes: 1_529_662_669,
            tokenizerRepo: "openai/whisper-medium.en"
        ),
        WhisperModelDescriptor(
            id: .medium,
            displayName: "Medium",
            upstreamCheckpoint: "medium",
            runtimeArtifact: "openai_whisper-medium",
            englishOnly: false,
            approximateDiskBytes: 1_529_662_669,
            tokenizerRepo: "openai/whisper-medium"
        ),
        WhisperModelDescriptor(
            id: .largeV2,
            displayName: "Large v2",
            upstreamCheckpoint: "large-v2",
            runtimeArtifact: "openai_whisper-large-v2",
            englishOnly: false,
            approximateDiskBytes: 3_090_048_614,
            tokenizerRepo: "openai/whisper-large-v2"
        ),
        WhisperModelDescriptor(
            id: .largeV3,
            displayName: "Large v3",
            upstreamCheckpoint: "large-v3",
            runtimeArtifact: "openai_whisper-large-v3",
            englishOnly: false,
            approximateDiskBytes: 3_090_363_187,
            tokenizerRepo: "openai/whisper-large-v3"
        ),
        WhisperModelDescriptor(
            id: .turbo,
            displayName: "Turbo",
            upstreamCheckpoint: "large-v3-turbo",
            runtimeArtifact: "openai_whisper-large-v3_turbo",
            englishOnly: false,
            approximateDiskBytes: 3_195_115_930,
            tokenizerRepo: "openai/whisper-large-v3"
        ),
    ]
}
