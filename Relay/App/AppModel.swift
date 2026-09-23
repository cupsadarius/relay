import Observation
@preconcurrency import AppKit

@MainActor
@Observable
final class AppModel {
    /// The graph this model was built from. Retained for the model's (= the app's) lifetime.
    @ObservationIgnored let runtime: RelayRuntime

    var statusText: String {
        get { runtime.status.message }
        set { runtime.status.post(newValue) }
    }

    /// Menu-bar status that tracks live activity (same source as the overlay pill) and falls
    /// back to the last transient message when idle, so it never shows a stale "Speaking…"
    /// after speech ends. Reads `overlayModel.state`, which is `@Observable`-tracked, so this
    /// updates the menu live even though `overlayModel` itself is `@ObservationIgnored` on
    /// `AppModel` (that annotation only suppresses tracking of reassigning the reference, not
    /// of reading properties through it).
    var activityStatusText: String {
        switch overlayModel.state {
        case .listening:
            "Listening…"
        case .processing:
            "Transcribing…"
        case .preparingSpeech:
            "Processing…"
        case .speaking:
            "Speaking…"
        case let .error(_, _, message):
            message
        case .hidden:
            statusText
        }
    }
    var diagnosticsEntries: [DiagnosticEntry] { diagnostics.entries.reversed() }
    var diagnosticsCounters: DiagnosticsCounters { diagnostics.counters }
    var overlayModel: ActivityOverlayModel { runtime.speechOut.overlayModel }
    private var speechCoordinator: any SpeechCoordinating { runtime.speechOut.speechCoordinator }
    private var diagnostics: DiagnosticsRecorder { runtime.diagnostics }
    private var overlayPresenter: any ActivityOverlayPresenting { runtime.speechOut.overlayPresenter }
    private var integrationDiagnosticsLog: IntegrationDiagnosticsLog { runtime.integrationDiagnosticsLog }

    @ObservationIgnored let integrationSetup: IntegrationSetupModel
    @ObservationIgnored let settingsController: SettingsController
    /// Read-only settings for views; writes go through `settingsController`.
    var settings: AppSettings { settingsController.current }
    @ObservationIgnored let permissions: PermissionsModel
    @ObservationIgnored let modelController: SpeechModelController
    @ObservationIgnored let voiceCatalog: SpeechVoiceCatalog
    @ObservationIgnored let speechActions: SpeechActions
    @ObservationIgnored let hotkeys: HotkeyController
    @ObservationIgnored let sttBackendList: BackendListModel
    @ObservationIgnored let ttsBackendList: BackendListModel
    /// The fire-and-forget initial status refresh kicked off from `init`. Exposed so tests can
    /// await it instead of racing an explicit `sttBackendList.refresh()` call against it.
    @ObservationIgnored var initialSpeechBackendRefresh: Task<Void, Never>?
    /// The fire-and-forget initial TTS status refresh kicked off from `init`. Exposed so tests
    /// can await it instead of racing an explicit `ttsBackendList.refresh()` call against it.
    @ObservationIgnored var initialTTSBackendRefresh: Task<Void, Never>?

    /// The only initializer. Production passes `RelayRuntime.makeProduction()`; tests pass
    /// `RelayRuntime.testing(...)`. No defaults: every dependency comes from `runtime`.
    init(runtime: RelayRuntime) {
        self.runtime = runtime
        integrationSetup = IntegrationSetupModel(runtime: runtime)
        settingsController = runtime.settingsController
        permissions = PermissionsModel(runtime: runtime)
        modelController = SpeechModelController(
            managers: Self.modelManagers(
                dictation: runtime.speechIn.speechModelManagers,
                textToSpeech: runtime.speechOut.ttsModelManagers
            ),
            diagnostics: runtime.diagnostics
        )
        voiceCatalog = SpeechVoiceCatalog()
        speechActions = SpeechActions(runtime: runtime, voiceCatalog: voiceCatalog)
        hotkeys = HotkeyController(runtime: runtime, speechActions: speechActions)
        let settings = runtime.settingsController
        sttBackendList = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechIn.sttRegistry),
            order: { settings.current.sttBackendOrder },
            setOrder: { settings.setSTTBackendOrder($0) },
            refusalMessage: "At least one speech recognition backend must stay enabled.",
            statusSink: runtime.status
        )
        ttsBackendList = BackendListModel(
            entries: BackendListEntry.entries(runtime.speechOut.ttsRegistry),
            order: { settings.current.ttsBackendOrder },
            setOrder: { settings.setTTSBackendOrder($0) },
            refusalMessage: "At least one TTS backend must stay enabled.",
            statusSink: runtime.status
        )
        configureModelController()
        settingsController.onHotkeysChanged = { [weak hotkeys = self.hotkeys] definitions in
            hotkeys?.definitionsChanged(definitions)
        }
        hotkeys.start()
        permissions.observeActivation { [weak self] in self?.recheckDiagnostics() }
        bindOverlayPresenter()
        initialSpeechBackendRefresh = Task { [weak self] in
            await self?.sttBackendList.refresh()
            await self?.modelController.refresh(domain: .dictation)
        }
        initialTTSBackendRefresh = Task { [weak self] in
            await self?.ttsBackendList.refresh()
            await self?.modelController.refresh(domain: .textToSpeech)
        }
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

    private func configureModelController() {
        modelController.configureHooks(
            refreshBackends: { [weak self] domain in
                switch domain {
                case .dictation:
                    await self?.sttBackendList.refresh()
                case .textToSpeech:
                    await self?.ttsBackendList.refresh()
                }
            },
            beforeRemoval: { [weak self] key in
                if key.domain == .textToSpeech {
                    self?.speechCoordinator.stop()
                }
            }
        )
    }

    func selectVoice(backendID: String, voiceID: String) {
        guard let value = voiceCatalog.storedValue(for: voiceID, backendID: backendID) else { return }
        settingsController.setVoice(value, for: backendID)
    }

    func setActivityOverlayStyle(_ style: ActivityOverlayStyle) {
        settingsController.setActivityOverlayStyle(style)
        overlayPresenter.update(state: overlayModel.state, style: style)
    }

    private func bindOverlayPresenter() {
        overlayModel.setStateHandler { [weak self] state in
            guard let self else { return }
            overlayPresenter.update(state: state, style: settingsController.current.activityOverlayStyle)
        }
    }

    func recheckDiagnostics() {
        permissions.recheck()
        hotkeys.ensureTap()
        Task { [weak self] in await self?.sttBackendList.refresh() }
    }

    func clearDiagnostics() { diagnostics.clear() }

    /// Snapshot of the integration-pipeline diagnostics log, newest first. Purely structural
    /// (stage/outcome/detail) — never response text, cwd, paths, environment, raw error text, or
    /// `providerSessionID`. Purely for diagnostics display.
    func integrationDiagnosticsEntries() -> [IntegrationDiagnosticsEntry] {
        integrationDiagnosticsLog.snapshot()
    }

    /// Removes all recorded integration-pipeline diagnostics entries.
    func clearIntegrationDiagnostics() {
        integrationDiagnosticsLog.clear()
    }
    var diagnosticsCopyText: String { diagnostics.copyText }
}

/// Default presenter for tests and any composition that doesn't host the overlay panel.
@MainActor
final class NoOpActivityOverlayPresenter: ActivityOverlayPresenting {
    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {}
}

extension HotkeyAction {
    var title: String {
        switch self {
        case .dictate: "Dictate"
        case .readSelection: "Read Selection"
        case .stopSpeech: "Stop Speech"
        case .replayLast: "Replay Last"
        case .toggleAutoRead: "Toggle Auto-read"
        }
    }
}
