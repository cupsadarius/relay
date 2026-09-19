import Foundation

/// Errors `AppleSpeechModelManager` throws. `unknownModel` covers any id other than
/// `AppleSpeechModelManager.modelID`; `removeNotSupported` mirrors `ParakeetModelManagerError
/// .removeNotSupported` -- see `removeModel`'s doc comment for why.
enum AppleSpeechModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
    case removeNotSupported
}

/// The zero-download `SpeechModelManaging` implementation for Relay's Apple Speech backend.
/// Apple Speech's recognizer ships as part of macOS -- there is no separate model file for Relay
/// to fetch, select among, or remove -- so this exists purely to give Apple Speech the SAME
/// collapsible provider-row + nested-model-list UI as Parakeet and Whisper
/// (`DictationSettingsView`), with zero backend-specific branches in the view. It is the "0/1
/// model" counterpart to `ParakeetModelManager`: `models()` always returns a single status that
/// is always downloaded and always selected.
///
/// A plain struct with no stored state: every property is fixed, so this needs no isolation of
/// its own (mirrors `ParakeetModelManager`).
struct AppleSpeechModelManager: SpeechModelManaging {
    /// Relay's one Apple Speech "model" id. Apple's on-device recognizer has no model file or
    /// public identifier of its own, so this is minted here purely as the id this
    /// `SpeechModelManaging` surface exposes.
    static let modelID = "apple-on-device"

    let backendID = "apple-speech"

    /// Always exactly one status: always `.downloaded` (it ships with macOS -- there is nothing
    /// to fetch), always selected (the one model IS the selection, mirroring
    /// `ParakeetModelManager`), and never reported "loaded" -- Apple Speech's
    /// `SpeechToTextBackend.prepare()`/`transcribe()` has no separate resident-model concept this
    /// could reflect, so this mirrors `ParakeetModelManager.models()`'s always-false `isLoaded`.
    func models() async -> [SpeechModelStatus] {
        [
            SpeechModelStatus(
                descriptor: Self.descriptor,
                installState: .downloaded,
                isSelected: true,
                isLoaded: false
            )
        ]
    }

    /// No-op success: the recognizer ships with macOS, so there is nothing to download. Still
    /// validates `id` so an unknown id fails loudly instead of silently succeeding.
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Self.validate(id)
    }

    /// No-op success beyond validating `id`: with exactly one model, "select" can't change
    /// anything (mirrors `ParakeetModelManager.selectModel`).
    func selectModel(_ id: String) async throws {
        try Self.validate(id)
    }

    /// Not applicable: Apple's on-device recognizer isn't a Relay-managed download, so there is
    /// nothing to remove. Validates `id` first (an unknown id still reports `unknownModel`, not
    /// `removeNotSupported`), then always throws -- mirrors `ParakeetModelManager.removeModel`.
    func removeModel(_ id: String) async throws {
        try Self.validate(id)
        throw AppleSpeechModelManagerError.removeNotSupported
    }

    private static let descriptor = SpeechModelDescriptor(
        id: modelID,
        displayName: "On-device",
        detail: nil,
        approximateDownloadBytes: nil
    )

    private static func validate(_ id: String) throws {
        guard id == modelID else {
            throw AppleSpeechModelManagerError.unknownModel(id)
        }
    }
}
