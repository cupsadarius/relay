import Foundation

/// A live, mutable box holding the latest `AppSettings` snapshot. `AppModel` is the sole writer
/// (via `updateSettings`), while every production service `RelayRuntime` constructs that needs to
/// read settings without depending on `AppModel` itself (the TTS/STT routers,
/// `DictationCoordinator`, `AgentAutoReadCoordinator`) reads through an `@MainActor`-isolated
/// closure captured over this box at construction time. That keeps every reader on the same
/// isolation domain as the one writer, with no synchronization beyond `@MainActor` itself.
@MainActor
final class SettingsBox {
    var value: AppSettings

    init(_ value: AppSettings) {
        self.value = value
    }
}

/// Session-intelligence services: the ephemeral in-memory agent-session registry, the
/// frontmost-app monitor, the process inspector (used both for focus resolution and for pruning
/// dead-process sessions), the recent-interaction tracker, and the resulting
/// `FocusResolutionService`. Resolver order is fixed: Herdr (exact pane evidence) -> tmux (exact
/// pane evidence, only when a tmux executable exists) -> generic terminal (conservative
/// process-ancestry fallback).
struct SessionServices {
    let registry: AgentSessionRegistry
    let frontmostApps: any FrontmostAppMonitoring
    let processInspector: ProcessInspector
    let recentInteractions: RecentInteractionTracker
    let focusResolution: any SessionFocusResolving
}

/// Speech-output services: the TTS backend registry/router pair, the model downloaders for
/// backends that need one (Kokoro, PocketTTS), the shared `SpeechCoordinator`, and the activity
/// overlay model/presenter pair the coordinator drives.
struct SpeechOutputServices {
    let ttsRegistry: [String: any TextToSpeechBackend]
    let ttsModelDownloaders: [String: any SpeechModelDownloading]
    let speechCoordinator: any SpeechCoordinating
    let overlayModel: ActivityOverlayModel
    let overlayPresenter: any ActivityOverlayPresenting
}

/// Speech-input services: the STT backend registry, its model downloaders (Parakeet), and the
/// dictation coordinator built around them. Kept as the CONCRETE `DictationCoordinator` type
/// (rather than only `any DictationCoordinating`) since `AppModel` still needs to call
/// `setStatusHandler` on it once `AppModel` itself exists.
struct SpeechInputServices {
    let sttRegistry: [String: any SpeechToTextBackend]
    let speechModelDownloaders: [String: any SpeechModelDownloading]
    let dictationCoordinator: DictationCoordinator?
}

/// Agent-integration services: the fixed-path Unix-socket receiver, the manager that decodes and
/// dispatches hook events (wired to auto-read), the per-provider installers, and the bundled
/// `RelayHook` helper installer/location.
struct IntegrationServices {
    let hookEnvelopeReceiver: HookEnvelopeReceiver
    let integrationManager: IntegrationManager
    let claudeCodeInstaller: ClaudeCodeInstaller
    let codexInstaller: CodexInstaller
    let helperInstaller: HelperInstaller
    let bundledHelperURL: URL
}

/// The composition root for Relay's production dependency graph. Constructs and OWNS every
/// subsystem's lifetime; `AppModel` (built via `AppModel(runtime:)`) reads services off this
/// instead of building them itself. Explicit initializer, no DI framework — see
/// `makeProduction()` for the real production graph and `RelayApp` for where it's constructed.
/// Never used by tests: every test constructs `AppModel` directly through its fakes-injecting
/// initializer instead.
@MainActor
final class RelayRuntime {
    let settingsStore: any SettingsStoring
    let settings: AppSettings
    let settingsBox: SettingsBox
    let diagnostics: DiagnosticsRecorder
    let integrationDiagnosticsLog: IntegrationDiagnosticsLog
    let permissionService: any GlobalPermissionAuthorizing
    let microphonePermissions: any MicrophonePermissionStatusProviding
    let privacySettingsOpener: any PrivacySettingsOpening
    let loginItemService: any LoginItemControlling
    let sessions: SessionServices
    let speechOut: SpeechOutputServices
    let speechIn: SpeechInputServices
    let integrations: IntegrationServices
    let hotkeyManager: any HotkeyManaging
    let selectionReader: any SelectionReading
    let preprocessor: RulesSpeechPreprocessor

    init(
        settingsStore: any SettingsStoring,
        settings: AppSettings,
        settingsBox: SettingsBox,
        diagnostics: DiagnosticsRecorder,
        integrationDiagnosticsLog: IntegrationDiagnosticsLog,
        permissionService: any GlobalPermissionAuthorizing,
        microphonePermissions: any MicrophonePermissionStatusProviding,
        privacySettingsOpener: any PrivacySettingsOpening,
        loginItemService: any LoginItemControlling,
        sessions: SessionServices,
        speechOut: SpeechOutputServices,
        speechIn: SpeechInputServices,
        integrations: IntegrationServices,
        hotkeyManager: any HotkeyManaging,
        selectionReader: any SelectionReading,
        preprocessor: RulesSpeechPreprocessor
    ) {
        self.settingsStore = settingsStore
        self.settings = settings
        self.settingsBox = settingsBox
        self.diagnostics = diagnostics
        self.integrationDiagnosticsLog = integrationDiagnosticsLog
        self.permissionService = permissionService
        self.microphonePermissions = microphonePermissions
        self.privacySettingsOpener = privacySettingsOpener
        self.loginItemService = loginItemService
        self.sessions = sessions
        self.speechOut = speechOut
        self.speechIn = speechIn
        self.integrations = integrations
        self.hotkeyManager = hotkeyManager
        self.selectionReader = selectionReader
        self.preprocessor = preprocessor
    }

    /// Builds Relay's real production dependency graph — exactly the graph `AppModel`'s
    /// production initializer used to build inline before `RelayRuntime` existed (see git
    /// history for `AppModel.swift` prior to Reliability Wave 3). Never call this from a test;
    /// construct fakes and pass them directly to `AppModel`'s fakes-injecting initializer
    /// instead.
    static func makeProduction() -> RelayRuntime {
        let settingsStore = SettingsStore()
        let settings = settingsStore.load()
        let settingsBox = SettingsBox(settings)
        let diagnostics = DiagnosticsRecorder()
        let overlayModel = ActivityOverlayModel()

        let appleTTS = AppleTTSBackend()
        let kokoroTTS = KokoroTTSBackend()
        let pocketTTS = PocketTTSBackend()
        let ttsRegistry: [String: any TextToSpeechBackend] = [
            appleTTS.id: appleTTS,
            kokoroTTS.id: kokoroTTS,
            pocketTTS.id: pocketTTS,
        ]
        let router = TTSRouter(
            backends: ttsRegistry,
            backendOrder: { settingsBox.value.ttsBackendOrder }
        )
        let coordinator = SpeechCoordinator(
            router: router,
            options: {
                TTSOptions(
                    voiceIdentifier: settingsBox.value.ttsVoiceIdentifier,
                    rate: settingsBox.value.ttsRate,
                    kokoroVoice: settingsBox.value.kokoroVoice,
                    pocketVoice: settingsBox.value.pocketVoice
                )
            },
            overlay: overlayModel
        )
        let sttBackend = AppleSpeechBackend()
        let parakeetBackend = ParakeetBackend()
        let sttRegistry: [String: any SpeechToTextBackend] = [
            sttBackend.id: sttBackend,
            parakeetBackend.id: parakeetBackend,
        ]

        // Phase 3 session-intelligence dependency graph. Every subsystem that needs
        // frontmost-app or recent-interaction evidence shares these SAME instances (passed into
        // `dictation` below) rather than constructing its own, so they all observe one
        // consistent view of focus state. Resolver order is fixed: Herdr (exact pane evidence) ->
        // tmux (exact pane evidence) -> generic terminal (conservative process-ancestry
        // fallback). tmux support is entirely optional: when no tmux executable is found,
        // `TmuxFocusResolver` is simply never added to the list.
        let sessionRegistry = AgentSessionRegistry()
        // One shared, in-memory diagnostics log for the integration pipeline, independent of
        // `os_log`. Passed into the receiver, manager, and auto-read coordinator below so their
        // entries interleave in a single timeline, readable from the Diagnostics window.
        let integrationDiagnosticsLog = IntegrationDiagnosticsLog()
        let processInspector = ProcessInspector()
        let frontmostApps = FrontmostAppMonitor()
        let recentInteractionTracker = RecentInteractionTracker()
        let tmuxRunner = TmuxExecutableLocator().locate().map { TmuxClient(executable: $0) }
        let herdrClient = HerdrSocketClient()
        let agentProcessContext = AgentProcessContextCapture(processInspector: processInspector)

        var resolvers: [any FocusResolver] = []
        resolvers.append(HerdrFocusResolver(
            herdr: herdrClient,
            hostOwnership: HerdrHostOwnershipChecker(processInspector: processInspector)
        ))
        if let tmuxRunner {
            resolvers.append(TmuxFocusResolver(runner: tmuxRunner, processTrees: processInspector))
        }
        resolvers.append(GenericTerminalFocusResolver())

        let focusResolution = FocusResolutionService(
            registry: sessionRegistry,
            frontmostApps: frontmostApps,
            resolvers: resolvers
        )
        let autoReadCoordinator = AgentAutoReadCoordinator(
            registry: sessionRegistry,
            processContext: agentProcessContext,
            focus: focusResolution,
            preprocess: { RulesSpeechPreprocessor().prepare(text: $0, mode: .automatic) },
            speech: coordinator,
            // `@MainActor` here (not merely `@Sendable`): `settingsBox.value` is only ever
            // WRITTEN on the MainActor (`AppModel.updateSettings`), so every reader must also
            // run there. This closure is invoked from `AgentAutoReadCoordinator`'s own actor
            // isolation as `await autoReadEnabled()`; being `@MainActor`-isolated makes that
            // call hop to the main actor to read `settingsBox.value`, landing in the same
            // isolation domain as every write — rather than reading the mutable, heap-backed
            // `AppSettings` struct across domains with no synchronization. A `@MainActor`
            // closure converts implicitly to the coordinator's plain
            // `@Sendable () async -> Bool` parameter type; the hop happens at the call site, not
            // by widening that parameter.
            autoReadEnabled: { @MainActor in settingsBox.value.autoReadEnabled },
            diagnostics: integrationDiagnosticsLog,
            processInspector: processInspector
        )

        let dictation = DictationCoordinator(
            microphone: MicrophoneCapture(onCaptureDiagnostics: { @MainActor (diagnosticsRecord: MicrophoneCaptureDiagnostics) in
                diagnostics.recordMicrophoneCapture(diagnosticsRecord)
            }),
            sttRouter: STTRouter(
                backends: sttRegistry,
                backendOrder: {
                    let configured = settingsBox.value.sttBackendOrder.filter { sttRegistry[$0] != nil }
                    return configured.isEmpty ? [sttBackend.id] : configured
                }
            ),
            processor: RulesTranscriptProcessor(),
            textInserter: TextInsertionService(),
            stopSpeech: { coordinator.stop() },
            status: { _ in },
            activity: overlayModel,
            diagnostics: diagnostics,
            frontmostApps: frontmostApps,
            recentInteractions: recentInteractionTracker,
            liveTranscriptionEnabled: { @MainActor in settingsBox.value.liveTranscriptionEnabled }
        )
        let hookEnvelopeReceiver = HookEnvelopeReceiver(diagnostics: integrationDiagnosticsLog)

        let integrationManager = IntegrationManager(
            events: hookEnvelopeReceiver.events,
            integrations: [ClaudeCodeIntegration(), CodexIntegration()],
            speechCoordinator: coordinator,
            diagnostics: integrationDiagnosticsLog,
            onResponse: { event in await autoReadCoordinator.handle(event) }
        )
        let actionDispatcher: any ActivityOverlayControlling = ActivityOverlayActionDispatcher(dictation: dictation, speech: coordinator)
        let overlayPresenter = ActivityOverlayWindowController(
            model: overlayModel,
            host: ActivityOverlayPanelHost(),
            screens: SystemActivityOverlayScreens(),
            diagnostics: diagnostics,
            onAction: { [actionDispatcher] action in actionDispatcher.perform(action) }
        )
        let speechModelDownloaders: [String: any SpeechModelDownloading] = [
            parakeetBackend.id: parakeetBackend,
        ]
        // Apple never registers a downloader, since it has no model to download.
        let ttsModelDownloaders: [String: any SpeechModelDownloading] = [
            kokoroTTS.id: kokoroTTS,
            pocketTTS.id: pocketTTS,
        ]

        return RelayRuntime(
            settingsStore: settingsStore,
            settings: settings,
            settingsBox: settingsBox,
            diagnostics: diagnostics,
            integrationDiagnosticsLog: integrationDiagnosticsLog,
            permissionService: PermissionService(),
            microphonePermissions: SystemMicrophonePermissionStatusProvider(),
            privacySettingsOpener: SystemPrivacySettingsOpener(),
            loginItemService: SystemLoginItemController(),
            sessions: SessionServices(
                registry: sessionRegistry,
                frontmostApps: frontmostApps,
                processInspector: processInspector,
                recentInteractions: recentInteractionTracker,
                focusResolution: focusResolution
            ),
            speechOut: SpeechOutputServices(
                ttsRegistry: ttsRegistry,
                ttsModelDownloaders: ttsModelDownloaders,
                speechCoordinator: coordinator,
                overlayModel: overlayModel,
                overlayPresenter: overlayPresenter
            ),
            speechIn: SpeechInputServices(
                sttRegistry: sttRegistry,
                speechModelDownloaders: speechModelDownloaders,
                dictationCoordinator: dictation
            ),
            integrations: IntegrationServices(
                hookEnvelopeReceiver: hookEnvelopeReceiver,
                integrationManager: integrationManager,
                claudeCodeInstaller: ClaudeCodeInstaller(),
                codexInstaller: CodexInstaller(),
                helperInstaller: HelperInstaller(),
                bundledHelperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RelayHook")
            ),
            hotkeyManager: GlobalHotkeyManager(diagnostics: diagnostics),
            selectionReader: SelectionReader(
                accessibility: AccessibilityService(),
                clipboard: ClipboardService()
            ),
            preprocessor: RulesSpeechPreprocessor()
        )
    }
}
