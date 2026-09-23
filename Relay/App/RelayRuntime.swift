import Foundation

/// Session-intelligence services: the ephemeral in-memory agent-session registry, the
/// frontmost-app monitor, the process inspector (used both for focus resolution and for pruning
/// dead-process sessions), and the resulting `FocusResolutionService`. Resolver order is fixed:
/// Herdr (exact pane evidence) -> tmux (exact pane evidence, only when a tmux executable exists)
/// -> generic terminal (conservative process-ancestry fallback).
struct SessionServices {
    let registry: AgentSessionRegistry
    let frontmostApps: any FrontmostAppMonitoring
    let processInspector: ProcessInspector
    let focusResolution: any SessionFocusResolving
}

/// Speech-output services: the TTS backend registry/router pair, post-Whisper model managers for
/// model-backed TTS providers, the shared `SpeechCoordinator`, and the activity overlay
/// model/presenter pair the coordinator drives.
struct SpeechOutputServices {
    let ttsRegistry: [String: any TextToSpeechBackend]
    let ttsModelManagers: [String: any SpeechModelManaging]
    let speechCoordinator: any SpeechCoordinating
    let overlayModel: ActivityOverlayModel
    let overlayPresenter: any ActivityOverlayPresenting
}

/// Speech-input services: the STT backend registry, its per-backend model managers, and the
/// dictation coordinator built around them.
struct SpeechInputServices {
    let sttRegistry: [String: any SpeechToTextBackend]
    let speechModelManagers: [String: any SpeechModelManaging]
    let dictationCoordinator: (any DictationCoordinating)?
}

/// Agent-integration services: the fixed-path Unix-socket receiver, the manager that decodes and
/// dispatches hook events (wired to auto-read), the per-provider installers, and the bundled
/// `RelayHook` helper installer/location.
struct IntegrationServices {
    /// Where `IntegrationSetupModel.start()` opens the hook socket. `productionSocketPath` in the
    /// app; a short temp path in tests (`RelayRuntime.testing`), so tests never bind the real one.
    let socketPath: String
    let hookEnvelopeReceiver: HookEnvelopeReceiver
    let integrationManager: IntegrationManager
    let claudeCodeInstaller: ClaudeCodeInstaller
    let codexInstaller: CodexInstaller
    let helperInstaller: HelperInstaller
    let bundledHelperURL: URL

    /// This build's socket (`Relay/relay.sock` for Release, `Relay Debug/relay.sock` for Debug).
    /// `RelayHook` derives the same path from its own location.
    static var productionSocketPath: String { RelayPaths.socketPath() }
}

/// The composition root for Relay's dependency graph. Constructs every subsystem; `AppModel`
/// retains the runtime (`AppModel.runtime`) for its whole life, which is what keeps every service
/// alive. Explicit initializer, no DI framework. Production uses `makeProduction()`; tests use
/// `RelayRuntime.testing(...)` in `RelayTests/Support/RelayRuntime+Testing.swift` and never
/// call `makeProduction()`.
@MainActor
final class RelayRuntime {
    let status: StatusSink
    let settingsController: SettingsController
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
        status: StatusSink,
        settingsController: SettingsController,
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
        self.status = status
        self.settingsController = settingsController
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

    /// Builds Relay's real production dependency graph. Touches UserDefaults, the CGEvent tap and
    /// real backends — never call from tests.
    static func makeProduction() -> RelayRuntime {
        let status = StatusSink()
        let diagnostics = DiagnosticsRecorder()
        let settingsController = SettingsController(
            store: SettingsStore(diagnostics: diagnostics),
            statusSink: status
        )
        let settings = settingsController.snapshot
        let overlayModel = ActivityOverlayModel()
        let graph = SpeechBackendGraph.make(
            whisperSelection: settingsController.whisperSelection,
            setWhisperSelection: settingsController.whisperSelectionWriter
        )
        let ttsRegistry = graph.ttsRegistry
        let sttRegistry = graph.sttRegistry

        let ttsPlayer = StreamingAudioPlayer()
        let router = TTSRouter(
            backends: ttsRegistry,
            backendOrder: { settings.value.ttsBackendOrder },
            player: ttsPlayer
        )
        let coordinator = SpeechCoordinator(
            router: router,
            options: { TTSOptions(settings: settings.value) },
            overlay: overlayModel
        )

        // Phase 3 session-intelligence dependency graph. Every subsystem that needs frontmost-app
        // evidence shares these SAME instances rather than constructing its own, so they all
        // observe one consistent view of focus state. Resolver order is fixed: Herdr (exact pane
        // evidence) -> tmux (exact pane evidence) -> generic terminal (conservative
        // process-ancestry fallback). tmux support is entirely optional: when no tmux executable
        // is found, `TmuxFocusResolver` is simply never added to the list.
        let sessionRegistry = AgentSessionRegistry()
        // One shared, in-memory diagnostics log for the integration pipeline, independent of
        // `os_log`. Passed into the receiver, manager, and auto-read coordinator below so their
        // entries interleave in a single timeline, readable from the Diagnostics window.
        let integrationDiagnosticsLog = IntegrationDiagnosticsLog()
        let processInspector = ProcessInspector()
        let frontmostApps = FrontmostAppMonitor()
        let tmuxRunner = TmuxExecutableLocator().locate().map { TmuxClient(executable: $0) }
        let herdrClient = HerdrSocketClient()

        var resolvers: [any FocusResolver] = []
        resolvers.append(HerdrFocusResolver(
            herdr: herdrClient,
            hostOwnership: HerdrHostOwnershipChecker()
        ))
        if let tmuxRunner {
            resolvers.append(TmuxFocusResolver(runner: tmuxRunner))
        }
        resolvers.append(GenericTerminalFocusResolver())

        let focusResolution = FocusResolutionService(
            registry: sessionRegistry,
            frontmostApps: frontmostApps,
            processSnapshots: processInspector,
            resolvers: resolvers
        )
        let autoReadCoordinator = AgentAutoReadCoordinator(
            registry: sessionRegistry,
            focus: focusResolution,
            preprocess: { RulesSpeechPreprocessor().prepare(text: $0, mode: .automatic) },
            speech: coordinator,
            autoReadEnabled: { settings.value.autoReadEnabled },
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
                    let configured = settings.value.sttBackendOrder.filter { sttRegistry[$0] != nil }
                    return configured.isEmpty ? [BackendID.appleSpeech.rawValue] : configured
                }
            ),
            processor: RulesTranscriptProcessor(),
            textInserter: TextInsertionService(),
            stopSpeech: { coordinator.stop() },
            status: { status.post($0) },
            activity: overlayModel,
            diagnostics: diagnostics,
            liveTranscriptionEnabled: { settings.value.liveTranscriptionEnabled }
        )
        let hookEnvelopeReceiver = HookEnvelopeReceiver(diagnostics: integrationDiagnosticsLog)

        let integrationManager = IntegrationManager(
            events: hookEnvelopeReceiver.events,
            integrations: [StopHookIntegration.claudeCode, StopHookIntegration.codex],
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
        return RelayRuntime(
            status: status,
            settingsController: settingsController,
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
                focusResolution: focusResolution
            ),
            speechOut: SpeechOutputServices(
                ttsRegistry: ttsRegistry,
                ttsModelManagers: graph.ttsModelManagers,
                speechCoordinator: coordinator,
                overlayModel: overlayModel,
                overlayPresenter: overlayPresenter
            ),
            speechIn: SpeechInputServices(
                sttRegistry: sttRegistry,
                speechModelManagers: graph.speechModelManagers,
                dictationCoordinator: dictation
            ),
            integrations: IntegrationServices(
                socketPath: IntegrationServices.productionSocketPath,
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
