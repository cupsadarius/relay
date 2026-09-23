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
    private(set) var microphonePermissionGranted: Bool
    /// Mirrors `loginItemService.isEnabled` (backed by `SMAppService.mainApp.status`), the OS's
    /// own source of truth for login-item registration. Never persisted separately in
    /// `AppSettings` — re-synced to the service on every write via `setLaunchAtLogin`, so it
    /// can't drift from what's actually registered.
    private(set) var launchAtLoginEnabled: Bool
    private(set) var dictationPhase: HotkeyPhase?
    private(set) var permissionSnapshot: PermissionSnapshot
    private(set) var eventTapStatus: HotkeyRegistrationStatus = .unavailable("Not checked")
    var diagnosticsEntries: [DiagnosticEntry] { diagnostics.entries.reversed() }
    var diagnosticsCounters: DiagnosticsCounters { diagnostics.counters }
    /// The most recent dictation capture attempt's privacy-safe metadata (input sample rate,
    /// frame count, timestamp) — never audio samples, transcript text, or file paths. Surfaced by
    /// the Security & Permissions settings tab so a stale post-rebuild microphone grant (zero
    /// frames captured despite the OS showing the toggle on) is visible rather than silent.
    var lastMicrophoneCaptureDiagnostics: MicrophoneCaptureDiagnostics? { diagnostics.lastMicrophoneCaptureDiagnostics }
    var overlayModel: ActivityOverlayModel { runtime.speechOut.overlayModel }
    private var selectionReader: any SelectionReading { runtime.selectionReader }
    private var preprocessor: RulesSpeechPreprocessor { runtime.preprocessor }
    private var speechCoordinator: any SpeechCoordinating { runtime.speechOut.speechCoordinator }
    private var dictationCoordinator: (any DictationCoordinating)? { runtime.speechIn.dictationCoordinator }
    private var hotkeyManager: any HotkeyManaging { runtime.hotkeyManager }
    private var permissionService: any GlobalPermissionAuthorizing { runtime.permissionService }
    private var microphonePermissions: any MicrophonePermissionStatusProviding { runtime.microphonePermissions }
    private var privacySettingsOpener: any PrivacySettingsOpening { runtime.privacySettingsOpener }
    private var loginItemService: any LoginItemControlling { runtime.loginItemService }
    private var diagnostics: DiagnosticsRecorder { runtime.diagnostics }
    private var overlayPresenter: any ActivityOverlayPresenting { runtime.speechOut.overlayPresenter }
    private var integrationManager: IntegrationManager { runtime.integrations.integrationManager }
    private var sessionRegistry: AgentSessionRegistry { runtime.sessions.registry }
    private var focusResolution: any SessionFocusResolving { runtime.sessions.focusResolution }
    private var frontmostApps: any FrontmostAppMonitoring { runtime.sessions.frontmostApps }
    private var processInspector: ProcessInspector { runtime.sessions.processInspector }
    private var integrationDiagnosticsLog: IntegrationDiagnosticsLog { runtime.integrationDiagnosticsLog }

    @ObservationIgnored let integrationSetup: IntegrationSetupModel
    @ObservationIgnored let settingsController: SettingsController
    /// Read-only settings for views; writes go through `settingsController`.
    var settings: AppSettings { settingsController.current }
    @ObservationIgnored let modelController: SpeechModelController
    @ObservationIgnored let voiceCatalog: SpeechVoiceCatalog
    @ObservationIgnored let sttBackendList: BackendListModel
    @ObservationIgnored let ttsBackendList: BackendListModel
    /// The fire-and-forget initial status refresh kicked off from `init`. Exposed so tests can
    /// await it instead of racing an explicit `sttBackendList.refresh()` call against it.
    @ObservationIgnored var initialSpeechBackendRefresh: Task<Void, Never>?
    /// The fire-and-forget initial TTS status refresh kicked off from `init`. Exposed so tests
    /// can await it instead of racing an explicit `ttsBackendList.refresh()` call against it.
    @ObservationIgnored var initialTTSBackendRefresh: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    /// The in-flight Read Selection / Replay Last action. Each new press of either hotkey, and
    /// Stop Speech, cancels it, so two quick presses can never both reach the speech coordinator.
    @ObservationIgnored private var speechActionTask: Task<Void, Never>?

    /// The only initializer. Production passes `RelayRuntime.makeProduction()`; tests pass
    /// `RelayRuntime.testing(...)`. No defaults: every dependency comes from `runtime`.
    init(runtime: RelayRuntime) {
        self.runtime = runtime
        integrationSetup = IntegrationSetupModel(runtime: runtime)
        settingsController = runtime.settingsController
        modelController = SpeechModelController(
            managers: Self.modelManagers(
                dictation: runtime.speechIn.speechModelManagers,
                textToSpeech: runtime.speechOut.ttsModelManagers
            ),
            diagnostics: runtime.diagnostics
        )
        voiceCatalog = SpeechVoiceCatalog()
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
        permissionSnapshot = runtime.permissionService.snapshot()
        microphonePermissionGranted = runtime.microphonePermissions.isGranted()
        launchAtLoginEnabled = runtime.loginItemService.isEnabled
        configureModelController()
        settingsController.onHotkeysChanged = { [weak self] _ in self?.registerHotkeys() }
        registerHotkeys()
        observeAppActivation()
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

    /// Registers/unregisters Relay as a login item via `loginItemService`
    /// (`SMAppService.mainApp` in production). A dev build running outside `/Applications` can
    /// legitimately fail to register; on failure this never crashes — it re-reads the service's
    /// actual status (so `launchAtLoginEnabled` can't drift from what's really registered) and
    /// surfaces a non-fatal status message instead.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemService.setEnabled(enabled)
            launchAtLoginEnabled = enabled
        } catch {
            launchAtLoginEnabled = loginItemService.isEnabled
            statusText = "Could not change launch-at-login."
        }
    }


    private func bindOverlayPresenter() {
        overlayModel.setStateHandler { [weak self] state in
            guard let self else { return }
            overlayPresenter.update(state: state, style: settingsController.current.activityOverlayStyle)
        }
    }

    private func registerHotkeys() {
        let status = hotkeyManager.register(settings: settings) { [weak self] action, phase in
            self?.handleHotkey(action, phase: phase)
        }
        eventTapStatus = status
        if case let .unavailable(message) = status {
            statusText = message
        }
    }

    func requestPermissions() {
        permissionService.requestPermissions()
        diagnostics.record(.permissionRequested)
        permissionSnapshot = permissionService.snapshot()
    }

    func requestMicrophonePermission() async {
        _ = await microphonePermissions.requestPermission()
        microphonePermissionGranted = microphonePermissions.isGranted()
        statusText = microphonePermissionGranted
            ? "Microphone permission granted"
            : "Allow Microphone permission in System Settings to dictate."
    }

    func openPrivacySettings(_ pane: PrivacySettingsPane) {
        privacySettingsOpener.open(pane)
    }

    /// Opens System Settings directly to Privacy & Security -> Microphone — the one-click fix for
    /// a stale microphone grant after a dev-signed rebuild: macOS keeps the toggle ON for the
    /// bundle id but delivers zero audio frames to the re-signed binary until the grant is
    /// toggled off and back on. Routes through the same injectable `privacySettingsOpener` seam
    /// as `openPrivacySettings(_:)` (backed by `NSWorkspace.shared.open(_:)` in production), so
    /// it's testable without touching real System Settings.
    func openMicrophoneSettings() {
        privacySettingsOpener.open(.microphone)
    }

    func recheckDiagnostics() {
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        diagnostics.record(.permissionRechecked)
        registerHotkeys()
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

    private func observeAppActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheckDiagnostics() }
        }
    }

    deinit {
        dictationTask?.cancel()
        speechActionTask?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    private func handleHotkey(_ action: HotkeyAction, phase: HotkeyPhase) {
        if action == .dictate {
            diagnostics.record(.actionDispatched(action: action, phase: phase))
            dictationPhase = phase
            guard dictationCoordinator != nil else { return }
            switch settings.dictationMode {
            case .holdToTalk:
                if phase == .pressed { enqueueDictation { await $0.start() } }
                else { enqueueDictation { await $0.finish() } }
            case .toggle:
                guard phase == .pressed else { return }
                enqueueDictation { await $0.toggle() }
            }
            return
        }
        guard phase == .pressed else { return }

        diagnostics.record(.actionDispatched(action: action, phase: phase))

        switch action {
        case .dictate:
            break
        case .readSelection:
            startSpeechAction { await $0.readSelection() }
        case .stopSpeech:
            speechActionTask?.cancel()
            speechActionTask = nil
            speechCoordinator.stop()
            diagnostics.record(.ttsStopped)
            statusText = "Speech stopped"
        case .replayLast:
            startSpeechAction { await $0.replayLast() }
        case .toggleAutoRead:
            settingsController.toggleAutoRead()
        }
    }

    /// Replaces any in-flight speech action with `action`. The cancelled one checks
    /// `Task.isCancelled` before speaking, so it never reaches the speech coordinator.
    private func startSpeechAction(_ action: @escaping @MainActor (AppModel) async -> Void) {
        speechActionTask?.cancel()
        speechActionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await action(self)
        }
    }

    private func enqueueDictation(
        _ operation: @escaping @MainActor (any DictationCoordinating) async -> Void
    ) {
        let previous = dictationTask
        let coordinator = dictationCoordinator
        dictationTask = Task { @MainActor in
            await previous?.value
            guard let coordinator else { return }
            await operation(coordinator)
        }
    }

    private func readSelection() async {
        do {
            let selection = try selectionReader.readSelection()
            diagnostics.record(selection.source == .accessibility ? .selectionAccessibility : .selectionClipboard)
            let prepared = preprocessor.prepare(text: selection.text, mode: .userRequested)
            let request = SpeechRequest(
                text: prepared,
                source: .selection,
                mode: .userRequested,
                sessionID: nil
            )
            guard !Task.isCancelled else { return }
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(error is SelectionReadingError ? .selectionUnavailable : .ttsFailed)
            statusText = error.localizedDescription
        }
    }

    /// Session-aware "Replay Last", tried in strict priority order:
    ///
    /// 1. **Focused agent session** — if some tracked agent session (Claude Code/Codex) is
    ///    confidently focused (`.focused` + `.high`), speak THAT session's last agent reply.
    /// 2. **Terminal focused but session ambiguous** — else, if the frontmost app hosts at least
    ///    one tracked agent session (by process ancestry) and a global latest agent reply exists,
    ///    speak that global latest.
    /// 3. **Non-agent context (e.g. Chrome) / nothing hosts a session** — fall back to replaying
    ///    the last spoken/selected text, exactly like the pre-existing behavior.
    ///
    /// All three tiers speak as an explicit user action (`.userRequested`), always audible
    /// regardless of the auto-read toggle. Iterating every tracked session's focus resolution is
    /// fine here: the session count is tiny, and the underlying `ps`/`lsof` calls are
    /// deadlock-hardened.
    private func replayLast() async {
        // One snapshot for this decision, shared by pruning and every focus resolver — the same
        // shape as `AgentAutoReadCoordinator.handle(_:)`.
        let snapshot = try? await processInspector.snapshot()
        await pruneDeadSessions(in: sessionRegistry, snapshot: snapshot)
        let sessions = await sessionRegistry.sessions()

        if let focused = await focusResolution.resolveFocus(among: sessions, processSnapshot: snapshot).focused {
            guard !Task.isCancelled else { return }
            await speakFocusedSessionReply(focused)
            return
        }

        guard !Task.isCancelled else { return }
        if let frontmostPID = await frontmostApps.current()?.pid,
           sessions.contains(where: { $0.processAncestry.contains(frontmostPID) }),
           integrationManager.latestResponse != nil,
           await speakGlobalLatestReply() {
            return
        }

        guard !Task.isCancelled else { return }
        await speakLastSpokenText()
    }

    /// Tier 1: speaks `session`'s own last agent reply via `IntegrationManager.speakResponse`, so
    /// the request is built identically to `speakLatest()` (same preprocessing, source, and
    /// sessionID derivation).
    private func speakFocusedSessionReply(_ session: AgentSession) async {
        do {
            try await integrationManager.speakResponse(session.latestResponse)
            diagnostics.record(.ttsSubmitted)
            integrationDiagnosticsLog.append(
                stage: "replay-last",
                outcome: "focused-session",
                detail: "provider=\(session.id.provider.rawValue)"
            )
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
        }
    }

    /// Tier 2: speaks the global latest agent reply via `IntegrationManager.speakLatest`. Called
    /// after confirming (via `integrationManager.latestResponse`) that a global latest reply
    /// looks available — but that check and `speakLatest()`'s own internal store read are two
    /// separate reads of related-but-distinct state, so this still handles `speakLatest()`
    /// reporting nothing to speak: it makes no diagnostics/statusText noise and returns `false`,
    /// letting `replayLast()`'s caller fall through to tier 3 instead of silently speaking
    /// nothing. Returns `true` for both an actual speak and a thrown speech failure — either way
    /// tier 2 has "handled" the request and `replayLast()` must not also fall through to tier 3
    /// (no double-speaking).
    private func speakGlobalLatestReply() async -> Bool {
        do {
            guard try await integrationManager.speakLatest() else { return false }
            diagnostics.record(.ttsSubmitted)
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "global-latest", detail: "")
            return true
        } catch is CancellationError {
            return true
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
            return true
        }
    }

    /// Tier 3: the original `SpeechCoordinator.replayLast()` behavior — re-speaks the last
    /// spoken/selected text, regardless of source.
    private func speakLastSpokenText() async {
        do {
            try await speechCoordinator.replayLast()
            diagnostics.record(.ttsReplayed)
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "last-spoken", detail: "")
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
        }
    }

    /// Fixed sample sentence spoken by each voice row's "Test" button (`previewVoice`). Never
    /// user-authored content, so it carries no privacy risk.
    private static let testVoiceSampleText = "This is a preview of the selected voice and speaking rate."

    func previewVoice(backendID: String, voiceID: String) async {
        guard let options = voiceCatalog.options(
            for: voiceID,
            backendID: backendID,
            settings: settings
        ) else { return }
        do {
            try await speechCoordinator.previewVoice(
                text: Self.testVoiceSampleText,
                backendID: backendID,
                options: options
            )
            diagnostics.record(.ttsSubmitted)
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = "Voice preview failed. Try again."
        }
    }

    // MARK: - Agent integrations

    /// Speaks the ephemeral latest agent response (if any) as a user-requested speech request.
    /// Never invoked automatically; only ever called from an explicit user action.
    func speakLatestAgentResponse() async {
        do {
            guard try await integrationManager.speakLatest() else {
                statusText = "No agent response to speak yet."
                return
            }
            diagnostics.record(.ttsSubmitted)
            // Clears a stale failure ("Could not speak…") or empty-store ("No agent response…")
            // message left over from an earlier call, the same way a fresh success elsewhere in
            // this file always leaves `statusText` at its clean default.
            statusText = "Ready"
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = "Could not speak the latest agent response."
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
