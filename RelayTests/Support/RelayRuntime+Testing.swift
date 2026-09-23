import Foundation
@testable import Relay

@MainActor
extension RelayRuntime {
    /// A `RelayRuntime` whose every service is a side-effect-free fake unless injected. Never
    /// touches `UserDefaults.standard`, the CGEvent tap, the real socket, `~/.claude`, `~/.codex`
    /// or `~/Library/Application Support`. Focus resolution defaults to a service over the SAME
    /// `sessionRegistry`/`frontmostApps` passed here — never a second registry.
    // NOTE (deviation from the plan text): the plan's version of this signature default-
    // constructs several `@MainActor`-isolated types (`SpySettingsStore()`, `StatusSink()`, ...)
    // directly as parameter default values. That fails to compile under this project's Swift 6.0
    // language mode ("call to main actor-isolated initializer ... in a synchronous nonisolated
    // context") — default-argument expressions are not treated as isolated to the enclosing
    // (extension) member's global actor here. Every such default is instead `nil` and
    // constructed inside the (MainActor-isolated) function body via `??`, exactly like the
    // plan's own `hookEnvelopeReceiver`/`claudeCodeInstaller`/etc. parameters already do.
    static func testing(
        settingsStore: (any SettingsStoring)? = nil,
        selectionReader: (any SelectionReading)? = nil,
        preprocessor: RulesSpeechPreprocessor = RulesSpeechPreprocessor(),
        speechCoordinator: (any SpeechCoordinating)? = nil,
        hotkeyManager: (any HotkeyManaging)? = nil,
        permissionService: (any GlobalPermissionAuthorizing)? = nil,
        microphonePermissions: (any MicrophonePermissionStatusProviding)? = nil,
        privacySettingsOpener: (any PrivacySettingsOpening)? = nil,
        loginItemService: (any LoginItemControlling)? = nil,
        diagnostics: DiagnosticsRecorder? = nil,
        integrationDiagnosticsLog: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        status: StatusSink? = nil,
        dictationCoordinator: (any DictationCoordinating)? = nil,
        overlayModel: ActivityOverlayModel? = nil,
        overlayPresenter: (any ActivityOverlayPresenting)? = nil,
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        ttsRegistry: [String: any TextToSpeechBackend] = [:],
        ttsModelManagers: [String: any SpeechModelManaging] = [:],
        hookEnvelopeReceiver: HookEnvelopeReceiver? = nil,
        integrationManager: IntegrationManager? = nil,
        claudeCodeInstaller: ClaudeCodeInstaller? = nil,
        codexInstaller: CodexInstaller? = nil,
        helperInstaller: HelperInstaller? = nil,
        bundledHelperURL: URL? = nil,
        hookSocketPath: String? = nil,
        sessionRegistry: AgentSessionRegistry = AgentSessionRegistry(),
        frontmostApps: (any FrontmostAppMonitoring)? = nil,
        focusResolution: (any SessionFocusResolving)? = nil,
        processInspector: ProcessInspector = ProcessInspector(runner: AllPIDsAliveProcessRunner())
    ) -> RelayRuntime {
        let settingsStore = settingsStore ?? SpySettingsStore()
        let selectionReader = selectionReader ?? SpySelectionReader()
        let speechCoordinator = speechCoordinator ?? SpySpeechCoordinator()
        let hotkeyManager = hotkeyManager ?? SpyHotkeyManager()
        let permissionService = permissionService ?? SpyPermissionService()
        let microphonePermissions = microphonePermissions ?? SpyMicrophonePermission(granted: true)
        let privacySettingsOpener = privacySettingsOpener ?? SpyPrivacyOpener()
        let loginItemService = loginItemService ?? SpyLoginItemController(enabled: false)
        let diagnostics = diagnostics ?? DiagnosticsRecorder(capacity: 10)
        let status = status ?? StatusSink()
        let overlayModel = overlayModel ?? ActivityOverlayModel()
        let overlayPresenter = overlayPresenter ?? NoOpActivityOverlayPresenter()
        let frontmostApps = frontmostApps ?? StubFrontmostAppMonitor(pid: nil)
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-tests-\(UUID().uuidString)", isDirectory: true)
        let helperPath = "/Applications/Relay.app/Contents/Helpers/RelayHook"
        let receiver = hookEnvelopeReceiver ?? HookEnvelopeReceiver(diagnostics: integrationDiagnosticsLog)
        let manager = integrationManager ?? IntegrationManager(
            events: receiver.events,
            integrations: [StopHookIntegration.claudeCode, StopHookIntegration.codex],
            speechCoordinator: speechCoordinator,
            diagnostics: integrationDiagnosticsLog
        )
        // Short on purpose: a unix socket path must fit in `sun_path` (104 bytes), and it must
        // never be the production socket.
        let socketPath = hookSocketPath ?? "/tmp/relay-rt-\(UUID().uuidString.prefix(8)).sock"
        return RelayRuntime(
            status: status,
            settingsController: SettingsController(store: settingsStore, statusSink: status),
            diagnostics: diagnostics,
            integrationDiagnosticsLog: integrationDiagnosticsLog,
            permissionService: permissionService,
            microphonePermissions: microphonePermissions,
            privacySettingsOpener: privacySettingsOpener,
            loginItemService: loginItemService,
            sessions: SessionServices(
                registry: sessionRegistry,
                frontmostApps: frontmostApps,
                processInspector: processInspector,
                focusResolution: focusResolution ?? FocusResolutionService(
                    registry: sessionRegistry,
                    frontmostApps: frontmostApps,
                    processSnapshots: processInspector,
                    resolvers: []
                )
            ),
            speechOut: SpeechOutputServices(
                ttsRegistry: ttsRegistry,
                ttsModelManagers: ttsModelManagers,
                speechCoordinator: speechCoordinator,
                overlayModel: overlayModel,
                overlayPresenter: overlayPresenter
            ),
            speechIn: SpeechInputServices(
                sttRegistry: sttRegistry,
                speechModelManagers: speechModelManagers,
                dictationCoordinator: dictationCoordinator
            ),
            integrations: IntegrationServices(
                socketPath: socketPath,
                hookEnvelopeReceiver: receiver,
                integrationManager: manager,
                claudeCodeInstaller: claudeCodeInstaller ?? ClaudeCodeInstaller(
                    baseDirectory: sandbox.appendingPathComponent("claude", isDirectory: true),
                    helperPath: helperPath
                ),
                codexInstaller: codexInstaller ?? CodexInstaller(
                    baseDirectory: sandbox.appendingPathComponent("codex", isDirectory: true),
                    helperPath: helperPath
                ),
                helperInstaller: helperInstaller ?? HelperInstaller(
                    baseDirectory: sandbox.appendingPathComponent("appsupport", isDirectory: true)
                ),
                bundledHelperURL: bundledHelperURL ?? sandbox
                    .appendingPathComponent("no-such-bundle", isDirectory: true)
                    .appendingPathComponent("RelayHook")
            ),
            hotkeyManager: hotkeyManager,
            selectionReader: selectionReader,
            preprocessor: preprocessor
        )
    }
}

// MARK: - Shared app-level test doubles

@MainActor
final class SpySettingsStore: SettingsStoring {
    let settings: AppSettings
    let saveError: Error?
    private(set) var saved: [AppSettings] = []

    init(settings: AppSettings = .defaults, saveError: Error? = nil) {
        self.settings = settings
        self.saveError = saveError
    }

    func load() -> AppSettings { settings }
    func save(_ value: AppSettings) throws {
        if let saveError { throw saveError }
        saved.append(value)
    }
}

@MainActor
final class SpySelectionReader: SelectionReading {
    let text: String
    private(set) var readCount = 0

    init(text: String = "selected") { self.text = text }

    func readSelection() throws -> SelectionResult {
        readCount += 1
        return .init(text: text, source: .accessibility)
    }
}

@MainActor
final class SpySpeechCoordinator: SpeechCoordinating {
    private(set) var requests: [SpeechRequest] = []
    private(set) var stopCount = 0
    private(set) var stoppedSessionIDs: [UUID] = []
    private(set) var replayCount = 0
    private(set) var previews: [(text: String, backendID: String, options: TTSOptions)] = []
    let replayError: Error?
    let speakError: Error?

    init(replayError: Error? = nil, speakError: Error? = nil) {
        self.replayError = replayError
        self.speakError = speakError
    }

    func speak(_ request: SpeechRequest) async throws {
        requests.append(request)
        if let speakError { throw speakError }
    }
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {
        previews.append((text, backendID, options))
        if let speakError { throw speakError }
    }
    func stop() { stopCount += 1 }
    func stop(sessionID: UUID) { stoppedSessionIDs.append(sessionID) }
    func replayLast() async throws {
        replayCount += 1
        if let replayError { throw replayError }
    }
}

@MainActor
final class SpyHotkeyManager: HotkeyManaging {
    private let status: HotkeyRegistrationStatus
    private var handler: (@MainActor (HotkeyAction, HotkeyPhase) -> Void)?
    private(set) var updates: [[HotkeyAction: HotkeyDefinition]] = []
    private(set) var ensureTapCount = 0

    init(status: HotkeyRegistrationStatus = .registered) { self.status = status }

    func setHandler(_ handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void) { self.handler = handler }
    func ensureTap() -> HotkeyRegistrationStatus { ensureTapCount += 1; return status }
    func update(definitions: [HotkeyAction: HotkeyDefinition]) { updates.append(definitions) }
    func send(_ action: HotkeyAction, _ phase: HotkeyPhase) { handler?(action, phase) }
}

@MainActor
final class SpyPermissionService: GlobalPermissionAuthorizing {
    let value: PermissionSnapshot
    private(set) var snapshotCount = 0
    private(set) var requestCount = 0

    init(snapshot: PermissionSnapshot = .init(inputMonitoringGranted: true, accessibilityGranted: true)) {
        value = snapshot
    }

    func snapshot() -> PermissionSnapshot { snapshotCount += 1; return value }
    func requestPermissions() { requestCount += 1 }
}

@MainActor
final class SpyMicrophonePermission: MicrophonePermissionStatusProviding {
    var grantedValue: Bool
    let requestResult: Bool
    private(set) var requestCount = 0

    init(granted: Bool, requestResult: Bool? = nil) {
        grantedValue = granted
        self.requestResult = requestResult ?? granted
    }

    func isGranted() -> Bool { grantedValue }
    func requestPermission() async -> Bool {
        requestCount += 1
        grantedValue = requestResult
        return requestResult
    }
}

@MainActor
final class SpyPrivacyOpener: PrivacySettingsOpening {
    private(set) var opened: [PrivacySettingsPane] = []
    func open(_ pane: PrivacySettingsPane) { opened.append(pane) }
}

@MainActor
final class SpyLoginItemController: LoginItemControlling {
    private(set) var isEnabled: Bool
    private(set) var setEnabledCalls: [Bool] = []
    private let setEnabledError: Error?

    init(enabled: Bool, setEnabledError: Error? = nil) {
        isEnabled = enabled
        self.setEnabledError = setEnabledError
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let setEnabledError { throw setEnabledError }
        isEnabled = enabled
    }
}

@MainActor
final class SpyDictationCoordinator: DictationCoordinating {
    private(set) var events: [String] = []
    private let blockStart: Bool
    private let blockFinish: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(blockStart: Bool = false, blockFinish: Bool = false) {
        self.blockStart = blockStart
        self.blockFinish = blockFinish
    }

    func start() async {
        events.append("start")
        if blockStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    func finish() async {
        events.append("finish")
        if blockFinish { await withCheckedContinuation { finishContinuation = $0 } }
    }
    func toggle() async {
        if events.last == "start" { await finish() } else { await start() }
    }
    func cancel(sessionID: UUID) async {}
    func resumeStart() { startContinuation?.resume(); startContinuation = nil }
    func resumeFinish() { finishContinuation?.resume(); finishContinuation = nil }
}

@MainActor
final class SpyOverlayPresenter: ActivityOverlayPresenting {
    private(set) var states: [ActivityOverlayState] = []
    private(set) var styles: [ActivityOverlayStyle] = []

    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {
        states.append(state)
        styles.append(style)
    }
}

/// Reports `focusedSessionID` (when set) as confidently `.focused`; everything else `.unknown`.
struct StubSessionFocusResolver: SessionFocusResolving {
    let focusedSessionID: AgentSessionID?
    func resolve(session: AgentSession) async -> FocusDecision {
        guard let focusedSessionID, session.id == focusedSessionID else {
            return .unknown(resolverID: "stub", reason: "not the stubbed focused session")
        }
        return .focused(resolverID: "stub", reason: "stubbed focused session")
    }
}

/// Reports a fixed frontmost pid, or no frontmost application when `pid` is nil.
struct StubFrontmostAppMonitor: FrontmostAppMonitoring {
    let pid: Int32?
    func current() async -> FrontmostApplication? {
        guard let pid else { return nil }
        return FrontmostApplication(pid: pid, bundleIdentifier: "com.test.terminal", localizedName: "TestTerminal")
    }
}

/// A process table where every pid in 1...10_000 is alive, so fabricated pids are never pruned.
final class AllPIDsAliveProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        let lines = (1...10_000).map { "\($0) 1 ttys001 fake" }.joined(separator: "\n")
        return ProcessResult(stdout: Data(lines.utf8), terminationStatus: 0)
    }
}

/// An empty process table: every pid looks dead.
final class AllPIDsDeadProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        ProcessResult(stdout: Data(), terminationStatus: 0)
    }
}

extension AgentResponseEvent {
    static func fixture(
        provider: AgentProvider = .claudeCode,
        providerSessionID: String,
        text: String = "Reply",
        parentPID: Int32 = 900,
        capturedAt: Date = Date()
    ) -> AgentResponseEvent {
        .init(
            id: UUID(), provider: provider, providerSessionID: providerSessionID,
            text: text, cwd: "/tmp/repo",
            parentPID: parentPID, environment: [:], capturedAt: capturedAt
        )
    }
}
