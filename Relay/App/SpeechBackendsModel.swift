import Foundation

struct CleanupModelRowItem: Identifiable, Equatable {
    let key: SpeechModelBackendKey
    let status: SpeechModelStatus
    var id: String { status.id }
    var modelID: CleanupModelID? { CleanupModelID(rawValue: status.id) }
}

/// Everything Settings shows about speech backends: per-domain readiness lists, per-backend model
/// lists, and the voice catalog. The single owner of refreshing them — views, launch and the
/// activation recheck all go through `refresh(_:)` / `refreshAll()`.
@MainActor
final class SpeechBackendsModel {
    let dictation: BackendListModel
    let textToSpeech: BackendListModel
    let models: SpeechModelController
    let voices: SpeechVoiceCatalog
    let cleanupTester: DictationCleanupTester?

    private let settings: SettingsController
    private let cleanup: any TranscriptCleaning

    init(runtime: RelayRuntime, voices: SpeechVoiceCatalog = SpeechVoiceCatalog()) {
        let settings = runtime.settingsController
        self.settings = settings
        self.voices = voices
        let dictation = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechIn.sttRegistry),
            order: { settings.current.sttBackendOrder },
            setOrder: { settings.setSTTBackendOrder($0) },
            refusalMessage: "At least one speech recognition backend must stay enabled.",
            statusSink: runtime.status
        )
        let textToSpeech = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechOut.ttsRegistry),
            order: { settings.current.ttsBackendOrder },
            setOrder: { settings.setTTSBackendOrder($0) },
            refusalMessage: "At least one TTS backend must stay enabled.",
            statusSink: runtime.status
        )
        let speechCoordinator = runtime.speechOut.speechCoordinator
        let cleanup = runtime.speechIn.transcriptCleanup
        let cleanupTester = runtime.speechIn.cleanupTester
        let cleanupRuntime = runtime.speechIn.cleanupRuntime
        self.dictation = dictation
        self.textToSpeech = textToSpeech
        self.cleanup = cleanup
        self.cleanupTester = cleanupTester
        models = SpeechModelController(
            managers: Self.modelManagers(
                dictation: runtime.speechIn.speechModelManagers,
                textToSpeech: runtime.speechOut.ttsModelManagers,
                dictationCleanup: runtime.speechIn.cleanupModelManagers
            ),
            diagnostics: runtime.diagnostics,
            refreshBackends: { domain in
                switch domain {
                case .dictation: await dictation.refresh()
                case .textToSpeech: await textToSpeech.refresh()
                // No readiness list; a selection or download change is when prewarm is re-evaluated.
                case .dictationCleanup: cleanup.prewarm()
                }
            },
            beforeRemoval: { key in
                switch key.domain {
                case .textToSpeech:
                    // Never delete a TTS model out from under an utterance that is streaming from it.
                    speechCoordinator.stop()
                case .dictationCleanup:
                    // Stop a Test and retire a long generation so unload(ifInvolving:) can drain.
                    cleanupTester?.cancelRunningTest(reason: .modelRemoved)
                    await cleanupRuntime?.retireGeneration()
                case .dictation:
                    break
                }
            }
        )
    }

    /// Every cleanup model row, in `CleanupModelID.allCases` order (Apple, Qwen 0.6B, Qwen 1.7B).
    var cleanupRows: [CleanupModelRowItem] {
        let order = CleanupModelID.allCases.map(\.rawValue)
        return models.models
            .filter { $0.key.domain == .dictationCleanup }
            .flatMap { key, rows in rows.map { CleanupModelRowItem(key: key, status: $0) } }
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    func list(for domain: SpeechModelDomain) -> BackendListModel? {
        switch domain {
        case .dictation: dictation
        case .textToSpeech: textToSpeech
        case .dictationCleanup: nil
        }
    }

    /// Readiness first (cheap, drives row state), then the model lists.
    func refresh(_ domain: SpeechModelDomain) async {
        await refreshReadiness(domain)
        await models.refresh(domain: domain)
    }

    /// Readiness rows only — for the app-activation recheck, where a permission change can flip
    /// a backend's readiness but cannot change which models are on disk.
    func refreshReadiness(_ domain: SpeechModelDomain) async {
        await list(for: domain)?.refresh()
    }

    /// Launch-time refresh. Sequential on purpose: dictation, then TTS, then cleanup. The old code
    /// ran the two domains as two concurrent tasks; on the main actor they interleaved anyway, and
    /// one ordered task is simpler to await in tests. Worst case the TTS rows appear after the
    /// dictation probes finish (a few hundred ms at launch, before Settings is usually open).
    /// Ends with the launch-time cleanup prewarm (spec §9.1).
    func refreshAll() async {
        await refresh(.dictation)
        await refresh(.textToSpeech)
        await refresh(.dictationCleanup)
        cleanup.prewarm()
    }

    /// The Settings toggle. Turning cleanup on prewarms the selected model; it never downloads or
    /// selects anything (spec §16).
    func setCleanupEnabled(_ enabled: Bool) {
        settings.setDictationCleanupEnabled(enabled)
        if enabled { cleanup.prewarm() }
    }

    func selectVoice(backendID: String, voiceID: String) {
        guard let value = voices.storedValue(for: voiceID, backendID: backendID) else { return }
        settings.setVoice(value, for: backendID)
    }

    private static func modelManagers(
        dictation: [String: any SpeechModelManaging],
        textToSpeech: [String: any SpeechModelManaging],
        dictationCleanup: [String: any SpeechModelManaging]
    ) -> SpeechModelController.Managers {
        var result: SpeechModelController.Managers = [:]
        for (backendID, manager) in dictation {
            result[SpeechModelBackendKey(domain: .dictation, backendID: backendID)] = manager
        }
        for (backendID, manager) in textToSpeech {
            result[SpeechModelBackendKey(domain: .textToSpeech, backendID: backendID)] = manager
        }
        for (backendID, manager) in dictationCleanup {
            result[SpeechModelBackendKey(domain: .dictationCleanup, backendID: backendID)] = manager
        }
        return result
    }
}
