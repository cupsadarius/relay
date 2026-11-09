import Foundation

/// Session-intelligence services: the ephemeral in-memory agent-session registry, the
/// frontmost-app monitor, the process inspector (used both for focus resolution and for pruning
/// dead-process sessions), and the resulting `FocusResolutionService`. Resolver order is fixed:
/// Herdr (exact pane evidence) -> Rex (focused block of the agent's Rex session) -> tmux (exact
/// pane evidence, only when a tmux executable exists) -> generic terminal (process ancestry).
struct SessionServices {
    let registry: AgentSessionRegistry
    let frontmostApps: any FrontmostAppMonitoring
    let processInspector: ProcessInspector
    let focusResolution: any SessionFocusResolving
}

/// Speech-output services: the TTS backend registry, model managers for model-backed TTS
/// providers, the shared `SpeechCoordinator`, and the activity overlay it drives.
struct SpeechOutputServices {
    let ttsRegistry: [BackendID: any TextToSpeechBackend]
    let ttsModelManagers: [BackendID: any SpeechModelManaging]
    let speechCoordinator: any SpeechCoordinating
    let overlayModel: ActivityOverlayModel
    let overlayPresenter: any ActivityOverlayPresenting
}

/// Speech-input services: the STT backend registry, its per-backend model managers, and the
/// dictation coordinator built around them.
struct SpeechInputServices {
    let sttRegistry: [BackendID: any SpeechToTextBackend]
    let speechModelManagers: [BackendID: any SpeechModelManaging]
    let dictationCoordinator: any DictationCoordinating
}

/// Agent-integration services: the fixed-path Unix-socket receiver, the manager that decodes and
/// dispatches hook events (wired to auto-read), the per-provider installers, and the bundled
/// `RelayHook` helper installer/location.
struct IntegrationServices {
    /// `RelayPaths.socketPath()` in the app; a short temp path in tests, so tests never bind the
    /// real socket.
    let socketPath: String
    let hookEnvelopeReceiver: HookEnvelopeReceiver
    let integrationManager: IntegrationManager
    let claudeCodeInstaller: ClaudeCodeInstaller
    let codexInstaller: CodexInstaller
    let helperInstaller: HelperInstaller
    let bundledHelperURL: URL
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
    /// Every module announces its step lifecycle here; `pipelineRuns` listens for Diagnostics.
    let pipeline: PipelineEventBus
    let pipelineRuns = PipelineRunStore()
    private var pipelineListener: Task<Void, Never>?

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
        preprocessor: RulesSpeechPreprocessor,
        pipeline: PipelineEventBus = PipelineEventBus()
    ) {
        self.pipeline = pipeline
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
        pipelineListener = pipelineRuns.listen(to: pipeline)
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
        let pipeline = PipelineEventBus()
        let graph = SpeechBackendGraph.make(
            whisperSelection: settingsController.modelSelection(for: .whisper),
            setWhisperSelection: settingsController.modelSelectionWriter(for: .whisper),
            parakeetSelection: settingsController.modelSelection(for: .parakeet),
            setParakeetSelection: settingsController.modelSelectionWriter(for: .parakeet)
        )
        let parakeetModelManager = graph.parakeetModelManager
        Task.detached { await parakeetModelManager.prewarmSelected() }
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
            options: {
                let current = settings.value
                return TTSOptions(settings: current)
            },
            overlay: overlayModel
        )

        // Every subsystem that needs focus evidence shares these instances, so they all see one
        // view of focus state.
        let sessionRegistry = AgentSessionRegistry()
        let integrationDiagnosticsLog = IntegrationDiagnosticsLog()
        let processInspector = ProcessInspector()
        let frontmostApps = FrontmostAppMonitor()
        let tmuxRunner = TmuxExecutableLocator().locate().map { TmuxClient(executable: $0) }
        let herdrClient = HerdrSocketClient()

        var resolvers: [any FocusResolver] = []
        resolvers.append(
            HerdrFocusResolver(
                herdr: herdrClient,
                hostOwnership: HerdrHostOwnershipChecker()
            ))
        resolvers.append(RexFocusResolver(rex: RexClient()))
        if let tmuxRunner {
            resolvers.append(TmuxFocusResolver(runner: tmuxRunner))
        }
        resolvers.append(GenericTerminalFocusResolver())

        let focusResolution = FocusResolutionService(frontmostApps: frontmostApps, resolvers: resolvers)
        let preprocessor = RulesSpeechPreprocessor()
        let autoReadCoordinator = AgentAutoReadCoordinator(
            registry: sessionRegistry,
            focus: focusResolution,
            preprocess: { preprocessor.prepare(text: $0) },
            speech: coordinator,
            autoReadEnabled: { settings.value.autoReadEnabled },
            diagnostics: integrationDiagnosticsLog,
            processInspector: processInspector,
            pipeline: pipeline
        )

        // Shared so ClipboardService's copy cycle and TextInsertionService's paste-fallback
        // write/restore cycle never interleave on the real pasteboard.
        let clipboardGate = ClipboardGate()

        let dictation = DictationCoordinator(
            microphone: MicrophoneCapture(
                source: CaptureSessionSource(
                    preferredMicrophone: { settings.value.selectedMicrophone },
                    releaseMonitor: MicrophoneReleaseMonitor(probe: CoreAudioProcessInputProbe()) { path in
                        Task { @MainActor in diagnostics.record(.dictation(.microphoneStillOpen(path))) }
                    },
                    onFallback: { name in
                        Task { @MainActor in diagnostics.record(.dictation(.microphoneFallback(missingName: name))) }
                    }
                ),
                onCaptureDiagnostics: { @MainActor (diagnosticsRecord: MicrophoneCaptureDiagnostics) in
                    diagnostics.recordMicrophoneCapture(diagnosticsRecord)
                }
            ),
            sttRouter: STTRouter(
                backends: sttRegistry,
                backendOrder: { settings.value.sttBackendOrder }
            ),
            processor: RulesTranscriptProcessor(),
            textInserter: TextInsertionService(gate: clipboardGate),
            stopSpeech: { coordinator.stop() },
            holdSpeech: { coordinator.holdAutomaticSpeech($0) },
            status: { status.post($0) },
            activity: overlayModel,
            diagnostics: diagnostics,
            pipeline: pipeline,
            liveTranscriptionEnabled: { settings.value.liveTranscriptionEnabled }
        )
        let hookEnvelopeReceiver = HookEnvelopeReceiver(diagnostics: integrationDiagnosticsLog)

        let integrationManager = IntegrationManager(
            events: hookEnvelopeReceiver.events,
            preprocessor: preprocessor,
            speechCoordinator: coordinator,
            diagnostics: integrationDiagnosticsLog,
            onResponse: { event in await autoReadCoordinator.handle(event) },
            onPrompt: { sessionID in await autoReadCoordinator.notePrompt(sessionID) }
        )
        let overlayPresenter = ActivityOverlayWindowController(
            model: overlayModel,
            host: ActivityOverlayPanelHost(),
            screens: SystemActivityOverlayScreens(),
            diagnostics: diagnostics,
            onAction: { [weak dictation, weak coordinator] action in
                guard let dictation, let coordinator else { return }
                await ActivityOverlayActions.perform(action, dictation: dictation, speech: coordinator)
            }
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
                socketPath: RelayPaths.socketPath(),
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
                clipboard: ClipboardService(gate: clipboardGate)
            ),
            preprocessor: preprocessor,
            pipeline: pipeline
        )
    }
}
