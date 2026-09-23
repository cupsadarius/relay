import XCTest

@testable import Relay

final class WhisperModelCatalogTests: XCTestCase {
    func testCatalogHasElevenModelsAndExcludesLargeV1() {
        XCTAssertEqual(WhisperModelID.allCases.count, 11)
        XCTAssertFalse(WhisperModelID.allCases.map(\.rawValue).contains("large-v1"))
    }

    func testEnglishOnlyFlagsAreCorrect() {
        XCTAssertTrue(WhisperModelCatalog.descriptor(for: .tinyEn).englishOnly)
        XCTAssertFalse(WhisperModelCatalog.descriptor(for: .turbo).englishOnly)
    }

    func testEveryModelHasNonEmptyArtifact() {
        for id in WhisperModelID.allCases {
            let d = WhisperModelCatalog.descriptor(for: id)
            XCTAssertFalse(d.runtimeArtifact.isEmpty)
        }
    }

    /// Every model needs a tokenizer HF repo so `WhisperModelStore` can fetch `tokenizer.json`
    /// (and friends) into the model folder -- see `testTokenizerRepoMatchesVerifiedWhisperKitMapping`
    /// for why each specific repo was chosen.
    func testEveryModelHasATokenizerRepoUnderOpenAIWhisper() {
        for id in WhisperModelID.allCases {
            let d = WhisperModelCatalog.descriptor(for: id)
            XCTAssertFalse(d.tokenizerRepo.isEmpty, "\(id) is missing a tokenizerRepo")
            XCTAssertTrue(
                d.tokenizerRepo.hasPrefix("openai/whisper-"),
                "\(id) tokenizerRepo '\(d.tokenizerRepo)' is not an openai/whisper-* repo"
            )
        }
    }

    /// Pins the exact tokenizer repo per model id, as resolved by WhisperKit 1.1.0's own
    /// `ModelUtilities.tokenizerNameForVariant` (argmax-oss-swift,
    /// Sources/WhisperKit/Utilities/ModelUtilities.swift) -- NOT guessed from the model id string.
    ///
    /// The `turbo` case is the one non-obvious entry: WhisperKit's `ModelVariant` enum has no
    /// `turbo` case at all. `ModelUtilities.detectVariant(logitsDim:encoderDim:)` classifies any
    /// loaded model purely from its decoder's actual logits/encoder dimensions, and `turbo`
    /// reports `logitsDim == 51866` -- identical to `large-v3` (turbo reuses large-v3's audio
    /// encoder and vocabulary byte-for-byte; see
    /// docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md section 2,
    /// data quality note 2) -- so `detectVariant` always classifies turbo as `.largev3`, and
    /// `tokenizerNameForVariant(.largev3)` resolves to `"openai/whisper-large-v3"`. WhisperKit
    /// will never request a `"openai/whisper-large-v3-turbo"`-named repo for this model, even
    /// though that repo does independently exist on Hugging Face.
    func testTokenizerRepoMatchesVerifiedWhisperKitMapping() {
        let expected: [WhisperModelID: String] = [
            .tinyEn: "openai/whisper-tiny.en",
            .tiny: "openai/whisper-tiny",
            .baseEn: "openai/whisper-base.en",
            .base: "openai/whisper-base",
            .smallEn: "openai/whisper-small.en",
            .small: "openai/whisper-small",
            .mediumEn: "openai/whisper-medium.en",
            .medium: "openai/whisper-medium",
            .largeV2: "openai/whisper-large-v2",
            .largeV3: "openai/whisper-large-v3",
            .turbo: "openai/whisper-large-v3",
        ]

        for (id, repo) in expected {
            XCTAssertEqual(WhisperModelCatalog.descriptor(for: id).tokenizerRepo, repo, "\(id)")
        }
    }
}
