import Foundation

/// The zero-download Apple Intelligence cleanup model (spec §12.5). Follows
/// `AppleSpeechModelManager`, but its selection is the global cleanup selection and its
/// usability tracks `SystemLanguageModel` availability.
struct AppleFoundationCleanupModelManager: SpeechModelManaging {
    /// Spike S2 decision: ship (see docs/superpowers/spikes/2026-09-24-dictation-cleanup-spike-results.md).
    /// Zero rate limiting observed on macOS 27; the row stays offered with no change.
    static let isOfferedInV1 = true
    /// Spike S2 `note` sets this to "May be skipped when Relay is in the background". Not set: S2 shipped clean.
    static let backgroundNote: String? = nil
    static let englishOnlyNote = "English only in this version"
    static let recommendedNote = "Recommended"

    let backendID = BackendID.appleFoundationCleanup.rawValue

    private let backend: any AppleCleanupBackending
    private let selectedModel: CleanupModelSelection
    private let setSelectedModel: CleanupModelSelectionWriter
    private let locale: @Sendable () -> Locale

    init(
        backend: any AppleCleanupBackending,
        selectedModel: @escaping CleanupModelSelection,
        setSelectedModel: @escaping CleanupModelSelectionWriter,
        locale: @escaping @Sendable () -> Locale = { .current }
    ) {
        self.backend = backend
        self.selectedModel = selectedModel
        self.setSelectedModel = setSelectedModel
        self.locale = locale
    }

    func models() async -> [SpeechModelStatus] {
        guard Self.isOfferedInV1 else { return [] }
        let usability: SpeechModelUsability
        switch backend.availability() {
        case .available: usability = .usable
        case .unavailable(let reason): usability = .unusable(reason: reason.rowText)
        }
        // The eval's best model (spike results, "Eval"): recommended whenever it can run.
        let recommended = usability == .usable ? Self.recommendedNote : nil
        let current = locale()
        let englishOnly = !TranscriptCleanupService.isEnglish(current) || !backend.supportsLocale(current)
        let detail = (["Built in"] + [recommended, englishOnly ? Self.englishOnlyNote : nil, Self.backgroundNote].compactMap { $0 })
            .joined(separator: " · ")
        return [
            SpeechModelStatus(
                descriptor: SpeechModelDescriptor(id: CleanupModelID.appleSystem.rawValue, displayName: CleanupModelID.appleSystem.displayName, detail: detail),
                capabilities: [.select],
                installState: .downloaded,
                isSelected: selectedModel() == .appleSystem,
                usability: usability
            )
        ]
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Self.validate(id)
        throw CleanupModelManagerError.notSupported
    }

    func selectModel(_ id: String) async throws {
        try Self.validate(id)
        guard backend.availability() == .available else { throw CleanupModelManagerError.unavailable }
        await setSelectedModel(.appleSystem)
    }

    func removeModel(_ id: String) async throws {
        try Self.validate(id)
        throw CleanupModelManagerError.notSupported
    }

    private static func validate(_ id: String) throws {
        guard id == CleanupModelID.appleSystem.rawValue, isOfferedInV1 else { throw CleanupModelManagerError.unknownModel(id) }
    }
}
