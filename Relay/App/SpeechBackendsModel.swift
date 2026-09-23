import Foundation

/// Everything Settings shows about speech backends: per-domain readiness lists, per-backend model
/// lists, and the voice catalog. The single owner of refreshing them — views, launch and the
/// activation recheck all go through `refresh(_:)` / `refreshAll()`.
@MainActor
final class SpeechBackendsModel {
    let dictation: BackendListModel
    let textToSpeech: BackendListModel
    let models: SpeechModelController
    let voices: SpeechVoiceCatalog

    private let settings: SettingsController

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
        self.dictation = dictation
        self.textToSpeech = textToSpeech
        models = SpeechModelController(
            managers: Self.modelManagers(
                dictation: runtime.speechIn.speechModelManagers,
                textToSpeech: runtime.speechOut.ttsModelManagers
            ),
            diagnostics: runtime.diagnostics,
            refreshBackends: { domain in
                switch domain {
                case .dictation: await dictation.refresh()
                case .textToSpeech: await textToSpeech.refresh()
                }
            },
            beforeRemoval: { key in
                // Never delete a TTS model out from under an utterance that is streaming from it.
                if key.domain == .textToSpeech { speechCoordinator.stop() }
            }
        )
    }

    func list(for domain: SpeechModelDomain) -> BackendListModel {
        switch domain {
        case .dictation: dictation
        case .textToSpeech: textToSpeech
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
        await list(for: domain).refresh()
    }

    /// Launch-time refresh. Sequential on purpose: dictation, then TTS. The old code ran the two
    /// domains as two concurrent tasks; on the main actor they interleaved anyway, and one
    /// ordered task is simpler to await in tests. Worst case the TTS rows appear after the
    /// dictation probes finish (a few hundred ms at launch, before Settings is usually open).
    func refreshAll() async {
        await refresh(.dictation)
        await refresh(.textToSpeech)
    }

    func selectVoice(backendID: String, voiceID: String) {
        guard let value = voices.storedValue(for: voiceID, backendID: backendID) else { return }
        settings.setVoice(value, for: backendID)
    }

    private static func modelManagers(
        dictation: [String: any SpeechModelManaging],
        textToSpeech: [String: any SpeechModelManaging]
    ) -> SpeechModelController.Managers {
        var result: SpeechModelController.Managers = [:]
        for (backendID, manager) in dictation {
            result[SpeechModelBackendKey(domain: .dictation, backendID: backendID)] = manager
        }
        for (backendID, manager) in textToSpeech {
            result[SpeechModelBackendKey(domain: .textToSpeech, backendID: backendID)] = manager
        }
        return result
    }
}
