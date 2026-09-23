@preconcurrency import AppKit
import Observation

/// The object every SwiftUI scene binds to. A thin facade: it builds the focused sub-models from
/// one `RelayRuntime`, retains that runtime for the app's lifetime, and exposes the sub-models
/// for views to call (`model.speechBackends.refresh(.dictation)`, `model.permissions.recheck()`).
/// Only values read almost everywhere (`settings`, `statusText`) and the diagnostics pass-throughs
/// live directly on it.
@MainActor
@Observable
final class AppModel {
    /// The graph this model was built from. Retained for the model's (= the app's) lifetime.
    @ObservationIgnored let runtime: RelayRuntime
    @ObservationIgnored let settingsController: SettingsController
    @ObservationIgnored let permissions: PermissionsModel
    @ObservationIgnored let integrationSetup: IntegrationSetupModel
    @ObservationIgnored let speechBackends: SpeechBackendsModel
    @ObservationIgnored let speechActions: SpeechActions
    @ObservationIgnored let hotkeys: HotkeyController
    /// Launch-time backend/model refresh; exposed so tests can await it.
    @ObservationIgnored private(set) var initialBackendRefresh: Task<Void, Never>?

    /// Read-only settings for views; writes go through `settingsController`.
    var settings: AppSettings { settingsController.current }
    /// The last transient status message (`StatusSink`).
    var statusText: String { runtime.status.message }
    var overlayModel: ActivityOverlayModel { runtime.speechOut.overlayModel }

    /// Menu-bar status: live activity (same source as the overlay pill), else the last message.
    /// Reads `overlayModel.state`, which is itself `@Observable`, so the menu updates live.
    var activityStatusText: String { overlayModel.state.menuStatusText(idle: statusText) }

    // MARK: Diagnostics pass-throughs (DiagnosticsView)

    var diagnosticsEntries: [DiagnosticEntry] { runtime.diagnostics.entries.reversed() }
    var diagnosticsCounters: DiagnosticsCounters { runtime.diagnostics.counters }
    var diagnosticsCopyText: String { runtime.diagnostics.copyText }
    func clearDiagnostics() { runtime.diagnostics.clear() }

    /// Integration-pipeline diagnostics, newest first. Structural only — never response text,
    /// cwd, paths, environment, raw error text, or `providerSessionID`.
    func integrationDiagnosticsEntries() -> [IntegrationDiagnosticsEntry] {
        runtime.integrationDiagnosticsLog.snapshot()
    }

    func clearIntegrationDiagnostics() { runtime.integrationDiagnosticsLog.clear() }

    // MARK: Lifecycle

    /// The only initializer. Production passes `RelayRuntime.makeProduction()`; tests pass
    /// `RelayRuntime.testing(...)`.
    init(runtime: RelayRuntime) {
        self.runtime = runtime
        settingsController = runtime.settingsController
        permissions = PermissionsModel(runtime: runtime)
        integrationSetup = IntegrationSetupModel(runtime: runtime)
        speechBackends = SpeechBackendsModel(runtime: runtime)
        speechActions = SpeechActions(runtime: runtime, voiceCatalog: speechBackends.voices)
        hotkeys = HotkeyController(runtime: runtime, speechActions: speechActions)

        settingsController.onHotkeysChanged = { [weak hotkeys] definitions in
            hotkeys?.definitionsChanged(definitions)
        }
        hotkeys.start()
        permissions.observeActivation { [weak self] in self?.recheckDiagnostics() }
        bindOverlayPresenter()
        initialBackendRefresh = Task { [speechBackends] in await speechBackends.refreshAll() }
    }

    /// Runs on every app activation and from the Diagnostics "Recheck" button: re-reads
    /// permissions, retries the event tap (without touching hotkey gesture state) and re-probes
    /// speech-recognition readiness (a granted mic can make Apple Speech ready).
    func recheckDiagnostics() {
        permissions.recheck()
        hotkeys.ensureTap()
        Task { [speechBackends] in await speechBackends.refreshReadiness(.dictation) }
    }

    func setActivityOverlayStyle(_ style: ActivityOverlayStyle) {
        settingsController.setActivityOverlayStyle(style)
        runtime.speechOut.overlayPresenter.update(state: overlayModel.state, style: style)
    }

    private func bindOverlayPresenter() {
        // Weak: the presenter (e.g. ActivityOverlayWindowController) holds `overlayModel`
        // strongly, so a strong capture here would cycle overlayModel -> this closure ->
        // presenter -> overlayModel.
        let presenter = runtime.speechOut.overlayPresenter
        let settings = settingsController
        overlayModel.setStateHandler { [weak presenter] state in
            presenter?.update(state: state, style: settings.current.activityOverlayStyle)
        }
    }
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
