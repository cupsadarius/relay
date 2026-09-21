import Observation
@preconcurrency import AppKit
import AVFoundation
import os

/// Thrown by `AppModel.installBundledHelperIfPresent` when, after attempting to refresh the
/// bundled `RelayHook` helper at its stable Application Support path, there is still no valid
/// (present and executable) helper there. Caught by `installIntegration`, which surfaces it as
/// `.configurationError` instead of proceeding to write the agent config — a config pointed at
/// a stable path with nothing runnable behind it would silently never fire.
enum HelperInstallVerificationError: Error, Sendable {
    case stableHelperUnavailable
}

@MainActor
@Observable
final class AppModel {
    var statusText = "Ready"
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
    private(set) var settings: AppSettings
    private(set) var dictationPhase: HotkeyPhase?
    private(set) var hotkeyConflictMessage: String?
    private(set) var permissionSnapshot: PermissionSnapshot
    private(set) var eventTapStatus: HotkeyRegistrationStatus = .unavailable("Not checked")
    var diagnosticsEntries: [DiagnosticEntry] { diagnostics.entries.reversed() }
    var diagnosticsCounters: DiagnosticsCounters { diagnostics.counters }
    /// The most recent dictation capture attempt's privacy-safe metadata (input sample rate,
    /// frame count, timestamp) — never audio samples, transcript text, or file paths. Surfaced by
    /// the Security & Permissions settings tab so a stale post-rebuild microphone grant (zero
    /// frames captured despite the OS showing the toggle on) is visible rather than silent.
    var lastMicrophoneCaptureDiagnostics: MicrophoneCaptureDiagnostics? { diagnostics.lastMicrophoneCaptureDiagnostics }
    var sttBackends: [STTBackendStatus] = []
    var speechBackendMessage: String?
    /// Per-model snapshot rows, keyed by backend id, populated by `refreshSpeechModels()`. Unlike
    /// `sttBackends` (one row per backend, derived from `availability()`), this is the per-model
    /// surface the Settings view needs to list/download/select/remove an individual model for a
    /// backend that offers more than one (Whisper). `models()` is async, so the view can't call it
    /// directly from `body` — it reads this instead. Settable (like `sttBackends`) only so
    /// `SpeechBackendCatalog.swift`'s `AppModel` extension can mutate it; callers outside `AppModel`
    /// should treat it as read-only.
    var speechModels: [String: [SpeechModelStatus]] = [:]
    /// Models with an in-flight download, keyed `"<backendID>/<modelID>"`. Tracked as an
    /// `@Observable`-visible property (unlike `downloadingBackendIDs`, which is bookkeeping-only)
    /// so the view can show per-row download activity without inferring it from `installState`.
    var downloadingModelKeys: Set<String> = []
    var ttsBackends: [TTSBackendStatus] = []
    var ttsBackendMessage: String?
    /// Whether the Relay agent-hook Unix socket is currently listening. Only ever flipped by
    /// `startIntegrations()`/`stopIntegrations()`, called from the real app lifecycle.
    private(set) var isSocketListening = false
    /// Install-time status per provider, refreshed by `installIntegration`/`uninstallIntegration`/
    /// `checkIntegration`. Independent of `integrationManager.status`, which tracks only runtime
    /// (event-driven) activity; `integrationStatus(for:)` merges the two.
    private(set) var installerStatuses: [AgentProvider: IntegrationStatus] = [:]
    @ObservationIgnored let overlayModel: ActivityOverlayModel

    @ObservationIgnored let sttRegistry: [String: any SpeechToTextBackend]
    @ObservationIgnored let speechModelManagers: [String: any SpeechModelManaging]
    @ObservationIgnored let ttsRegistry: [String: any TextToSpeechBackend]
    @ObservationIgnored let ttsModelManagers: [String: any SpeechModelManaging]
    @ObservationIgnored var downloadingBackendIDs: Set<String> = []
    @ObservationIgnored var refreshGeneration = 0
    /// Generation counter for `refreshSpeechModels()`, mirroring `refreshGeneration`'s race-safety
    /// pattern: a refresh that was superseded by a later one must not apply its (older) results
    /// after the newer one has already won.
    @ObservationIgnored var speechModelsRefreshGeneration = 0
    @ObservationIgnored var downloadingTTSBackendIDs: Set<String> = []
    @ObservationIgnored var ttsRefreshGeneration = 0
    /// The fire-and-forget initial status refresh kicked off from `init`. Exposed so tests can
    /// await it instead of racing an explicit `refreshSpeechBackendStatuses()` call against it.
    @ObservationIgnored var initialSpeechBackendRefresh: Task<Void, Never>?
    /// The fire-and-forget initial TTS status refresh kicked off from `init`. Exposed so tests
    /// can await it instead of racing an explicit `refreshTTSBackendStatuses()` call against it.
    @ObservationIgnored var initialTTSBackendRefresh: Task<Void, Never>?
    @ObservationIgnored private let settingsStore: any SettingsStoring
    @ObservationIgnored private let selectionReader: any SelectionReading
    @ObservationIgnored private let preprocessor: RulesSpeechPreprocessor
    @ObservationIgnored private let speechCoordinator: any SpeechCoordinating
    @ObservationIgnored private let dictationCoordinator: (any DictationCoordinating)?
    @ObservationIgnored private let hotkeyManager: any HotkeyManaging
    @ObservationIgnored private let settingsState: SettingsBox
    @ObservationIgnored private let permissionService: any GlobalPermissionAuthorizing
    @ObservationIgnored private let microphonePermissions: any MicrophonePermissionStatusProviding
    @ObservationIgnored private let privacySettingsOpener: any PrivacySettingsOpening
    @ObservationIgnored private let loginItemService: any LoginItemControlling
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private let overlayPresenter: any ActivityOverlayPresenting
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    @ObservationIgnored private let hookEnvelopeReceiver: HookEnvelopeReceiver
    @ObservationIgnored private let integrationManager: IntegrationManager
    @ObservationIgnored private let claudeCodeInstaller: ClaudeCodeInstaller
    @ObservationIgnored private let codexInstaller: CodexInstaller
    /// Copies the bundled `RelayHook` helper to its stable Application Support location
    /// before each `installIntegration` call, so the stable path the installers reference
    /// always exists. Injectable so tests never touch the real `~/Library/Application
    /// Support`.
    @ObservationIgnored private let helperInstaller: HelperInstaller
    /// The bundled helper's location inside the running app bundle — the SOURCE
    /// `helperInstaller` copies from. Injectable so tests can point it at a path that never
    /// exists (the default is a no-op guard: see `installBundledHelperIfPresent`).
    @ObservationIgnored private let bundledHelperURL: URL
    /// Structural-only logging for `installBundledHelperIfPresent` (no paths, no file
    /// contents — see that method's doc comment for what gets logged and when).
    @ObservationIgnored private let installerLogger = Logger(subsystem: "dev.relaymac.Relay", category: "integrations")
    /// Ephemeral, memory-only registry of agent sessions observed from hook events. Shared with
    /// the production `AgentAutoReadCoordinator`/`FocusResolutionService` graph built in the
    /// `RelayRuntime.makeProduction()` graph. Exposed read-only for compact diagnostics
    /// (`agentSessionSummaries()`) — never for response text or live focus resolution.
    @ObservationIgnored private let sessionRegistry: AgentSessionRegistry
    /// Shared focus-resolution service consulted by `replayLast()` to find a confidently-focused
    /// agent session. The SAME instance shared with the production `AgentAutoReadCoordinator`
    /// graph built by `RelayRuntime.makeProduction()` — never a second instance.
    @ObservationIgnored private let focusResolution: any SessionFocusResolving
    /// Shared frontmost-application monitor consulted by `replayLast()`'s tier-2 check (does the
    /// frontmost app host at least one agent session). The SAME instance shared with the
    /// production dictation/auto-read graph built by `RelayRuntime.makeProduction()`.
    @ObservationIgnored private let frontmostApps: any FrontmostAppMonitoring
    /// Shared process inspector consulted by `replayLast()` to prune dead-process sessions from
    /// `sessionRegistry` before resolving focus. The SAME instance shared with the production
    /// `AgentAutoReadCoordinator`/resolver graph built by `RelayRuntime.makeProduction()`.
    @ObservationIgnored private let processInspector: ProcessInspector
    /// Shared in-memory diagnostics log for the integration pipeline (socket receive -> envelope
    /// decode -> adapter decode -> registry upsert -> focus gate), independent of `os_log`. The
    /// SAME instance is passed into `hookEnvelopeReceiver`, `integrationManager`, and the
    /// production `AgentAutoReadCoordinator` so their entries interleave in one timeline. Exposed
    /// read-only via `integrationDiagnosticsEntries()`/`clearIntegrationDiagnostics()` for the
    /// Diagnostics window.
    @ObservationIgnored private let integrationDiagnosticsLog: IntegrationDiagnosticsLog

    /// Builds the real production `AppModel` around `RelayRuntime`'s freshly constructed
    /// dependency graph. `AppModel` itself never builds that graph — see `RelayRuntime
    /// .makeProduction()` for where every subsystem in it is actually constructed.
    convenience init(runtime: RelayRuntime) {
        self.init(
            settingsStore: runtime.settingsStore,
            selectionReader: runtime.selectionReader,
            preprocessor: runtime.preprocessor,
            speechCoordinator: runtime.speechOut.speechCoordinator,
            hotkeyManager: runtime.hotkeyManager,
            loadedSettings: runtime.settings,
            settingsState: runtime.settingsBox,
            permissionService: runtime.permissionService,
            diagnostics: runtime.diagnostics,
            dictationCoordinator: runtime.speechIn.dictationCoordinator,
            microphonePermissions: runtime.microphonePermissions,
            privacySettingsOpener: runtime.privacySettingsOpener,
            loginItemService: runtime.loginItemService,
            overlayModel: runtime.speechOut.overlayModel,
            overlayPresenter: runtime.speechOut.overlayPresenter,
            sttRegistry: runtime.speechIn.sttRegistry,
            speechModelManagers: runtime.speechIn.speechModelManagers,
            ttsRegistry: runtime.speechOut.ttsRegistry,
            ttsModelManagers: runtime.speechOut.ttsModelManagers,
            hookEnvelopeReceiver: runtime.integrations.hookEnvelopeReceiver,
            integrationManager: runtime.integrations.integrationManager,
            claudeCodeInstaller: runtime.integrations.claudeCodeInstaller,
            codexInstaller: runtime.integrations.codexInstaller,
            helperInstaller: runtime.integrations.helperInstaller,
            bundledHelperURL: runtime.integrations.bundledHelperURL,
            sessionRegistry: runtime.sessions.registry,
            focusResolution: runtime.sessions.focusResolution,
            frontmostApps: runtime.sessions.frontmostApps,
            processInspector: runtime.sessions.processInspector,
            integrationDiagnosticsLog: runtime.integrationDiagnosticsLog
        )
        runtime.speechIn.dictationCoordinator?.setStatusHandler { [weak self] in self?.statusText = $0 }
        // Postponed wiring (see `WhisperSelectionWriterBox`'s doc comment): `RelayRuntime
        // .makeProduction()` builds `WhisperModelManager`'s selection writer before `AppModel`
        // exists, so it starts as a no-op; re-point it at `setSelectedSpeechModel` now that
        // `AppModel` -- the app's sole settings writer -- does exist.
        runtime.speechIn.whisperSelectionWriter.persist = { [weak self] modelID in
            self?.setSelectedSpeechModel(backendID: "whisper", modelID: modelID?.rawValue)
        }
    }

    init(
        settingsStore: any SettingsStoring,
        selectionReader: any SelectionReading,
        preprocessor: RulesSpeechPreprocessor,
        speechCoordinator: any SpeechCoordinating,
        hotkeyManager: any HotkeyManaging,
        permissionService: any GlobalPermissionAuthorizing = PermissionService(),
        diagnostics: DiagnosticsRecorder = DiagnosticsRecorder(),
        dictationCoordinator: (any DictationCoordinating)? = nil,
        microphonePermissions: any MicrophonePermissionStatusProviding = SystemMicrophonePermissionStatusProvider(),
        privacySettingsOpener: any PrivacySettingsOpening = SystemPrivacySettingsOpener(),
        loginItemService: any LoginItemControlling = SystemLoginItemController(),
        overlayModel: ActivityOverlayModel = ActivityOverlayModel(),
        overlayPresenter: any ActivityOverlayPresenting = NoOpActivityOverlayPresenter(),
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        ttsRegistry: [String: any TextToSpeechBackend] = [:],
        ttsModelManagers: [String: any SpeechModelManaging] = [:],
        hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver(),
        integrationManager: IntegrationManager? = nil,
        claudeCodeInstaller: ClaudeCodeInstaller = ClaudeCodeInstaller(),
        codexInstaller: CodexInstaller = CodexInstaller(),
        helperInstaller: HelperInstaller = HelperInstaller(),
        bundledHelperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RelayHook"),
        sessionRegistry: AgentSessionRegistry = AgentSessionRegistry(),
        focusResolution: any SessionFocusResolving = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: FrontmostAppMonitor(),
            resolvers: []
        ),
        frontmostApps: any FrontmostAppMonitoring = FrontmostAppMonitor(),
        processInspector: ProcessInspector = ProcessInspector(),
        integrationDiagnosticsLog: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog()
    ) {
        let settings = settingsStore.load()
        self.settingsStore = settingsStore
        self.selectionReader = selectionReader
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.dictationCoordinator = dictationCoordinator
        self.hotkeyManager = hotkeyManager
        self.permissionService = permissionService
        self.microphonePermissions = microphonePermissions
        self.privacySettingsOpener = privacySettingsOpener
        self.loginItemService = loginItemService
        self.diagnostics = diagnostics
        self.overlayModel = overlayModel
        self.overlayPresenter = overlayPresenter
        self.sttRegistry = sttRegistry
        self.speechModelManagers = speechModelManagers
        self.ttsRegistry = ttsRegistry
        self.ttsModelManagers = ttsModelManagers
        self.hookEnvelopeReceiver = hookEnvelopeReceiver
        self.integrationManager = integrationManager ?? IntegrationManager(
            events: hookEnvelopeReceiver.events,
            integrations: [ClaudeCodeIntegration(), CodexIntegration()],
            speechCoordinator: speechCoordinator,
            diagnostics: integrationDiagnosticsLog
        )
        self.claudeCodeInstaller = claudeCodeInstaller
        self.codexInstaller = codexInstaller
        self.helperInstaller = helperInstaller
        self.bundledHelperURL = bundledHelperURL
        self.sessionRegistry = sessionRegistry
        self.focusResolution = focusResolution
        self.frontmostApps = frontmostApps
        self.processInspector = processInspector
        self.integrationDiagnosticsLog = integrationDiagnosticsLog
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        launchAtLoginEnabled = loginItemService.isEnabled
        self.settings = settings
        let state = SettingsBox(settings)
        settingsState = state
        registerHotkeys()
        observeAppActivation()
        bindOverlayPresenter()
        initialSpeechBackendRefresh = Task { [weak self] in await self?.refreshSpeechBackendStatuses() }
        initialTTSBackendRefresh = Task { [weak self] in await self?.refreshTTSBackendStatuses() }
    }

    private init(
        settingsStore: any SettingsStoring,
        selectionReader: any SelectionReading,
        preprocessor: RulesSpeechPreprocessor,
        speechCoordinator: any SpeechCoordinating,
        hotkeyManager: any HotkeyManaging,
        loadedSettings: AppSettings,
        settingsState: SettingsBox,
        permissionService: any GlobalPermissionAuthorizing,
        diagnostics: DiagnosticsRecorder,
        dictationCoordinator: (any DictationCoordinating)?,
        microphonePermissions: any MicrophonePermissionStatusProviding,
        privacySettingsOpener: any PrivacySettingsOpening,
        loginItemService: any LoginItemControlling = SystemLoginItemController(),
        overlayModel: ActivityOverlayModel,
        overlayPresenter: any ActivityOverlayPresenting,
        sttRegistry: [String: any SpeechToTextBackend],
        speechModelManagers: [String: any SpeechModelManaging],
        ttsRegistry: [String: any TextToSpeechBackend],
        ttsModelManagers: [String: any SpeechModelManaging],
        hookEnvelopeReceiver: HookEnvelopeReceiver,
        integrationManager: IntegrationManager,
        claudeCodeInstaller: ClaudeCodeInstaller,
        codexInstaller: CodexInstaller,
        helperInstaller: HelperInstaller = HelperInstaller(),
        bundledHelperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RelayHook"),
        sessionRegistry: AgentSessionRegistry,
        focusResolution: any SessionFocusResolving,
        frontmostApps: any FrontmostAppMonitoring,
        processInspector: ProcessInspector,
        integrationDiagnosticsLog: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog()
    ) {
        self.settingsStore = settingsStore
        self.selectionReader = selectionReader
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.dictationCoordinator = dictationCoordinator
        self.hotkeyManager = hotkeyManager
        self.permissionService = permissionService
        self.microphonePermissions = microphonePermissions
        self.privacySettingsOpener = privacySettingsOpener
        self.loginItemService = loginItemService
        self.diagnostics = diagnostics
        self.overlayModel = overlayModel
        self.overlayPresenter = overlayPresenter
        self.sttRegistry = sttRegistry
        self.speechModelManagers = speechModelManagers
        self.ttsRegistry = ttsRegistry
        self.ttsModelManagers = ttsModelManagers
        self.hookEnvelopeReceiver = hookEnvelopeReceiver
        self.integrationManager = integrationManager
        self.claudeCodeInstaller = claudeCodeInstaller
        self.codexInstaller = codexInstaller
        self.helperInstaller = helperInstaller
        self.bundledHelperURL = bundledHelperURL
        self.sessionRegistry = sessionRegistry
        self.focusResolution = focusResolution
        self.frontmostApps = frontmostApps
        self.processInspector = processInspector
        self.integrationDiagnosticsLog = integrationDiagnosticsLog
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        launchAtLoginEnabled = loginItemService.isEnabled
        settings = loadedSettings
        self.settingsState = settingsState
        registerHotkeys()
        observeAppActivation()
        bindOverlayPresenter()
        initialSpeechBackendRefresh = Task { [weak self] in await self?.refreshSpeechBackendStatuses() }
        initialTTSBackendRefresh = Task { [weak self] in await self?.refreshTTSBackendStatuses() }
    }

    func setHotkey(_ definition: HotkeyDefinition, for action: HotkeyAction) {
        if let conflictingAction = HotkeyAction.allCases.first(where: {
            guard $0 != action, let existing = settings.hotkeys[$0] else { return false }
            return definition.conflicts(with: existing)
        }) {
            let message = "\(action.title) conflicts with \(conflictingAction.title). Choose a different shortcut."
            hotkeyConflictMessage = message
            statusText = message
            return
        }
        hotkeyConflictMessage = nil
        updateSettings { $0.hotkeys[action] = definition }
    }

    func removeHotkey(for action: HotkeyAction) {
        hotkeyConflictMessage = nil
        updateSettings { $0.hotkeys[action] = nil }
    }

    func setDictationMode(_ mode: DictationMode) {
        updateSettings { $0.dictationMode = mode }
    }

    func setVoiceIdentifier(_ identifier: String?) {
        updateSettings { $0.ttsVoiceIdentifier = identifier }
    }

    func setKokoroVoice(_ voice: String?) {
        updateSettings { $0.kokoroVoice = voice }
    }

    func setPocketVoice(_ voice: String?) {
        updateSettings { $0.pocketVoice = voice }
    }

    func setSpeechRate(_ rate: Float) {
        updateSettings { $0.ttsRate = rate }
    }

    func setActivityOverlayStyle(_ style: ActivityOverlayStyle) {
        updateSettings { $0.activityOverlayStyle = style }
        overlayPresenter.update(state: overlayModel.state, style: style)
    }

    func setLiveTranscriptionEnabled(_ enabled: Bool) {
        updateSettings { $0.liveTranscriptionEnabled = enabled }
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
            overlayPresenter.update(state: state, style: settingsState.value.activityOverlayStyle)
        }
    }

    private func updateSettings(_ update: (inout AppSettings) -> Void) {
        let previousHotkeys = settings.hotkeys
        update(&settings)
        settingsState.value = settings
        // Only a change to the hotkey DEFINITIONS needs to rebuild `HotkeyMatcher` (which
        // `registerHotkeys()` does via `hotkeyManager.register`). Rebuilding it on every settings
        // write — voice, rate, backend order, auto-read, etc. — discarded any in-flight
        // chord/double-tap gesture state for no reason; the event tap itself is unaffected either
        // way (already idempotently guarded inside `GlobalHotkeyManager.register`).
        if settings.hotkeys != previousHotkeys {
            registerHotkeys()
        }
        do {
            try settingsStore.save(settings)
        } catch {
            statusText = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// The single write path `SpeechBackendCatalog.swift` uses to persist `sttBackendOrder`,
    /// kept narrow so that file doesn't need broader access to `updateSettings`.
    func setSTTBackendOrder(_ order: [String]) {
        updateSettings { $0.sttBackendOrder = order }
    }

    /// The single write path `TTSBackendCatalog.swift` uses to persist `ttsBackendOrder`, kept
    /// narrow so that file doesn't need broader access to `updateSettings`.
    func setTTSBackendOrder(_ order: [String]) {
        updateSettings { $0.ttsBackendOrder = order }
    }

    /// Persists a multi-model STT backend's currently-selected model id (e.g. Whisper's). Never
    /// called directly by `SpeechBackendCatalog.swift`; `RelayRuntime.makeProduction()` wires
    /// `WhisperSelectionWriterBox.persist` to this method right after constructing `AppModel`
    /// (see `AppModel(runtime:)` below), so `WhisperModelManager.selectModel` -- which runs
    /// before `AppModel` exists in `RelayRuntime.makeProduction()`'s own construction order --
    /// still ultimately routes its persistence through `updateSettings`, `AppModel`'s sole write
    /// path, instead of a production service writing `SettingsBox`/disk directly.
    func setSelectedSpeechModel(backendID: String, modelID: String?) {
        updateSettings { $0.selectedSpeechModelByBackend[backendID] = modelID }
    }

    /// Lets `SpeechBackendCatalog.swift` record diagnostics without widening `diagnostics` past
    /// this file.
    func recordDiagnostic(_ event: DiagnosticsEvent) {
        diagnostics.record(event)
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
        Task { [weak self] in await self?.refreshSpeechBackendStatuses() }
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
            Task { await readSelection() }
        case .stopSpeech:
            speechCoordinator.stop()
            diagnostics.record(.ttsStopped)
            statusText = "Speech stopped"
        case .replayLast:
            Task { await replayLast() }
        case .toggleAutoRead:
            toggleAutoRead()
        }
    }

    /// Flips `settings.autoReadEnabled` and updates `statusText` to reflect the new value.
    /// Shared by the `toggleAutoRead` hotkey and the menu bar's auto-read control so neither
    /// path duplicates the toggle logic.
    func toggleAutoRead() {
        setAutoReadEnabled(!settings.autoReadEnabled)
    }

    /// Sets `settings.autoReadEnabled` explicitly and updates `statusText` to reflect the new
    /// value. Used by the Integrations settings tab's toggle; `toggleAutoRead()` (the
    /// `.toggleAutoRead` hotkey and menu bar control) is expressed in terms of this so neither
    /// path duplicates the persist-and-announce logic. A no-op when the value is unchanged, so
    /// flipping the same settings-tab toggle repeatedly doesn't spam `statusText`.
    func setAutoReadEnabled(_ enabled: Bool) {
        guard enabled != settings.autoReadEnabled else { return }
        updateSettings { $0.autoReadEnabled = enabled }
        statusText = settings.autoReadEnabled ? "Auto-read enabled" : "Auto-read disabled"
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
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
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
        // Prune stale sessions before this tier-1/tier-2 read, same as
        // `AgentAutoReadCoordinator`: a dead-process session (or one gone quiet past the TTL)
        // must not be offered to focus resolution or treated as hosting the frontmost terminal.
        await pruneDeadSessions(in: sessionRegistry, using: processInspector)
        let sessions = await sessionRegistry.sessions()

        for session in sessions {
            let decision = await focusResolution.resolve(session: session)
            guard decision.state == .focused, decision.confidence == .high else { continue }
            await speakFocusedSessionReply(session)
            return
        }

        if let frontmostPID = await frontmostApps.current()?.pid,
           sessions.contains(where: { $0.processAncestry.contains(frontmostPID) }),
           integrationManager.latestResponse != nil,
           await speakGlobalLatestReply() {
            return
        }

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
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
        }
    }

    /// Fixed sample sentence spoken by the TTS tab's "Test Voice" button. Never user-authored
    /// content, so routing it through the normal speak path carries no privacy risk.
    private static let testVoiceSampleText = "This is a preview of the selected voice and speaking rate."

    /// Speaks a fixed sample sentence through the current TTS backend order and options (voice,
    /// rate). Used by the TTS settings tab's Test Voice button.
    func testVoice() async {
        let request = SpeechRequest(
            text: Self.testVoiceSampleText,
            source: .testVoice,
            mode: .userRequested,
            sessionID: nil
        )
        do {
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
        }
    }

    // MARK: - Agent integrations

    /// The fixed Unix-domain socket location Relay listens on for local agent-hook envelopes.
    /// Must match `RelayHook`'s `HookTransportClient.defaultSocketPath` exactly.
    static var integrationSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Relay/relay.sock")
            .path
    }

    /// Starts listening for local agent-hook envelopes on the fixed Relay socket path and begins
    /// dispatching decoded events through `integrationManager`.
    ///
    /// - Important: called ONLY from the real app lifecycle (`RelayApp.applicationDidFinishLaunching`).
    ///   Never called from any initializer, so constructing an `AppModel` in a test never opens a
    ///   real socket. A failure to start the socket never crashes the app; `isSocketListening` is
    ///   always set from `hookEnvelopeReceiver.isListening` afterward, so it stays authoritative
    ///   even when the start attempt throws (e.g. `.alreadyStarted` on a redundant call) while the
    ///   socket the receiver already holds open remains listening.
    func startIntegrations() {
        try? hookEnvelopeReceiver.start(path: Self.integrationSocketPath)
        isSocketListening = hookEnvelopeReceiver.isListening
        integrationManager.start()
    }

    /// Stops dispatching agent-hook events and stops/unlinks the Unix socket.
    ///
    /// - Important: called ONLY from `RelayApp.applicationWillTerminate`.
    func stopIntegrations() {
        integrationManager.stop()
        hookEnvelopeReceiver.stop()
        isSocketListening = false
    }

    /// The status shown to the user for `provider`: the manager's live `.active` runtime status
    /// when present, else the most recently checked install-time status.
    func integrationStatus(for provider: AgentProvider) -> IntegrationStatus {
        if let runtimeStatus = integrationManager.status[provider], case .active = runtimeStatus {
            return runtimeStatus
        }
        return installerStatuses[provider] ?? .notInstalled
    }

    /// Whether an ephemeral latest agent response is currently available to speak.
    var latestAgentResponseAvailable: Bool {
        integrationManager.latestResponse != nil
    }

    /// Installs the Relay `Stop` hook for `provider`, then refreshes its status. An installer
    /// failure — including the bundled helper not being reachable at its stable path (see
    /// `installBundledHelperIfPresent`) — is caught and surfaced as `.configurationError`
    /// BEFORE the per-provider installer writes the agent config; it never crashes the app,
    /// and never logs the underlying error verbatim. This ordering matters: the config must
    /// never point at a stable path with nothing runnable there, which would silently never
    /// fire while `status()` still reports "installed".
    func installIntegration(_ provider: AgentProvider) {
        do {
            try installBundledHelperIfPresent()
            switch provider {
            case .claudeCode: try claudeCodeInstaller.install()
            case .codex: try codexInstaller.install()
            }
            checkIntegration(provider)
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    /// Refreshes the stable-path copy of the bundled `RelayHook` helper (see
    /// `HelperInstaller`) before a per-provider installer runs, so the path it is about to
    /// write into the agent's config always resolves to a real, executable file — even right
    /// after a rebuild that produced a new bundled helper.
    ///
    /// Guarded on `bundledHelperURL` actually existing: in unit tests (and any host process
    /// that isn't the real, built app bundle) it normally doesn't, so this is a silent no-op
    /// there rather than a hard dependency on a real app bundle being present.
    ///
    /// When a bundled helper DOES exist, the copy is attempted and the destination is then
    /// re-verified with `FileManager.isExecutableFile`. A copy failure is NOT always fatal: if
    /// a valid helper from an earlier install is already sitting at the stable path,
    /// `installBundledHelper` never touches it on failure (see that type's doc comment), so
    /// the existing, still-working install is left alone — logged structurally, not surfaced.
    /// It's only fatal when, after the attempt, there is NO valid helper at the stable path at
    /// all: writing the agent config next would then point at a path nothing can ever run
    /// from, so this throws instead, aborting `installIntegration` before that write happens.
    private func installBundledHelperIfPresent() throws {
        guard FileManager.default.fileExists(atPath: bundledHelperURL.path) else { return }

        let fileManager = FileManager.default
        let installedHelperPath = helperInstaller.installedHelperURL.path
        let hadValidStableHelperBefore = fileManager.isExecutableFile(atPath: installedHelperPath)

        do {
            try helperInstaller.installBundledHelper(from: bundledHelperURL)
        } catch {
            if hadValidStableHelperBefore {
                installerLogger.log("bundled RelayHook helper refresh failed; a previously installed helper is still present")
            } else {
                installerLogger.log("bundled RelayHook helper refresh failed")
            }
        }

        guard fileManager.isExecutableFile(atPath: installedHelperPath) else {
            installerLogger.log("stable RelayHook helper unavailable after refresh; aborting hook install")
            throw HelperInstallVerificationError.stableHelperUnavailable
        }
    }

    /// Removes the Relay-owned `Stop` hook for `provider`, then refreshes its status. An
    /// installer failure is caught and surfaced as `.configurationError`; it never crashes the
    /// app, and never logs the underlying error verbatim.
    ///
    /// On success, also clears `provider`'s runtime status on `integrationManager` so a stale
    /// `.active` entry from earlier this session can't keep `integrationStatus(for:)` reporting
    /// active after the provider has just been uninstalled; `checkIntegration` then reloads the
    /// truthful post-uninstall state straight from the installer.
    func uninstallIntegration(_ provider: AgentProvider) {
        do {
            switch provider {
            case .claudeCode: try claudeCodeInstaller.uninstall()
            case .codex: try codexInstaller.uninstall()
            }
            integrationManager.clearRuntimeStatus(for: provider)
            checkIntegration(provider)
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    /// Refreshes `provider`'s install-time status by re-reading its agent config. A read failure
    /// is caught and surfaced as `.configurationError`; it never crashes the app, and never logs
    /// the underlying error verbatim.
    func checkIntegration(_ provider: AgentProvider) {
        do {
            switch provider {
            case .claudeCode: installerStatuses[provider] = try claudeCodeInstaller.status()
            case .codex: installerStatuses[provider] = try codexInstaller.status()
            }
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    /// Maps a thrown installer error to a user-facing `.configurationError`, without ever
    /// including the underlying error's text (which may carry file paths or content).
    private static func configurationErrorStatus(for provider: AgentProvider, error: Error) -> IntegrationStatus {
        if provider == .codex, case CodexInstallerError.hooksDisabledInConfig = error {
            return .configurationError(CodexInstaller.hooksDisabledMessage)
        }
        switch provider {
        case .claudeCode: return .configurationError("Could not update the Claude Code integration.")
        case .codex: return .configurationError("Could not update the Codex integration.")
        }
    }

    /// Speaks the ephemeral latest agent response (if any) as a user-requested speech request.
    /// Never invoked automatically; only ever called from an explicit user action.
    func speakLatestAgentResponse() async {
        do {
            try await integrationManager.speakLatest()
            diagnostics.record(.ttsSubmitted)
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = "Could not speak the latest agent response."
        }
    }

    /// Compact, privacy-safe metadata for one ephemeral agent session: provider, working
    /// directory, and last-activity time only. Never the response text, and never a resolved
    /// focus verdict — focus is only ever resolved at speak time by
    /// `AgentAutoReadCoordinator`/`FocusResolutionService`, not for display.
    struct AgentSessionSummary: Identifiable, Equatable, Sendable {
        let id: AgentSessionID
        let cwd: String
        let lastActivityAt: Date

        var provider: AgentProvider { id.provider }
    }

    /// Snapshot of the in-memory agent sessions currently tracked by Phase 3's session registry,
    /// most-recently-active first. Purely for diagnostics display; contents are never persisted
    /// and never include response text.
    func agentSessionSummaries() async -> [AgentSessionSummary] {
        await sessionRegistry.sessions().map {
            AgentSessionSummary(id: $0.id, cwd: $0.cwd, lastActivityAt: $0.lastActivityAt)
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
