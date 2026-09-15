import Observation
@preconcurrency import AppKit
import AVFoundation

@MainActor
@Observable
final class AppModel {
    private final class SettingsState {
        var value: AppSettings

        init(_ value: AppSettings) {
            self.value = value
        }
    }

    var statusText = "Ready"
    private(set) var microphonePermissionGranted: Bool
    private(set) var settings: AppSettings
    private(set) var dictationPhase: HotkeyPhase?
    private(set) var hotkeyConflictMessage: String?
    private(set) var permissionSnapshot: PermissionSnapshot
    private(set) var eventTapStatus: HotkeyRegistrationStatus = .unavailable("Not checked")
    var diagnosticsEntries: [DiagnosticEntry] { diagnostics.entries.reversed() }
    var diagnosticsCounters: DiagnosticsCounters { diagnostics.counters }
    var sttBackends: [STTBackendStatus] = []
    var speechBackendMessage: String?
    var ttsBackends: [TTSBackendStatus] = []
    var ttsBackendMessage: String?
    @ObservationIgnored let overlayModel: ActivityOverlayModel

    @ObservationIgnored let sttRegistry: [String: any SpeechToTextBackend]
    @ObservationIgnored let speechModelDownloaders: [String: any SpeechModelDownloading]
    @ObservationIgnored let ttsRegistry: [String: any TextToSpeechBackend]
    @ObservationIgnored let ttsModelDownloaders: [String: any SpeechModelDownloading]
    @ObservationIgnored var downloadingBackendIDs: Set<String> = []
    @ObservationIgnored var refreshGeneration = 0
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
    @ObservationIgnored private let settingsState: SettingsState
    @ObservationIgnored private let permissionService: any GlobalPermissionAuthorizing
    @ObservationIgnored private let microphonePermissions: any MicrophonePermissionStatusProviding
    @ObservationIgnored private let privacySettingsOpener: any PrivacySettingsOpening
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private let overlayPresenter: any ActivityOverlayPresenting
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var dictationTask: Task<Void, Never>?

    convenience init() {
        let settingsStore = SettingsStore()
        let settings = settingsStore.load()
        let state = SettingsState(settings)
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
            backendOrder: { state.value.ttsBackendOrder }
        )
        let coordinator = SpeechCoordinator(
            router: router,
            options: {
                TTSOptions(
                    voiceIdentifier: state.value.ttsVoiceIdentifier,
                    rate: state.value.ttsRate,
                    kokoroVoice: state.value.kokoroVoice,
                    pocketVoice: state.value.pocketVoice
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
        let dictation = DictationCoordinator(
            microphone: MicrophoneCapture(),
            sttRouter: STTRouter(
                backends: sttRegistry,
                backendOrder: {
                    let configured = state.value.sttBackendOrder.filter { sttRegistry[$0] != nil }
                    return configured.isEmpty ? [sttBackend.id] : configured
                }
            ),
            processor: RulesTranscriptProcessor(),
            textInserter: TextInsertionService(),
            stopSpeech: { coordinator.stop() },
            status: { _ in },
            activity: overlayModel,
            diagnostics: diagnostics
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
        self.init(
            settingsStore: settingsStore,
            selectionReader: SelectionReader(
                accessibility: AccessibilityService(),
                clipboard: ClipboardService()
            ),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: coordinator,
            hotkeyManager: GlobalHotkeyManager(diagnostics: diagnostics),
            loadedSettings: settings,
            settingsState: state,
            permissionService: PermissionService(),
            diagnostics: diagnostics,
            dictationCoordinator: dictation,
            microphonePermissions: SystemMicrophonePermissionStatusProvider(),
            privacySettingsOpener: SystemPrivacySettingsOpener(),
            overlayModel: overlayModel,
            overlayPresenter: overlayPresenter,
            sttRegistry: sttRegistry,
            speechModelDownloaders: speechModelDownloaders,
            ttsRegistry: ttsRegistry,
            ttsModelDownloaders: ttsModelDownloaders
        )
        dictation.setStatusHandler { [weak self] in self?.statusText = $0 }
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
        overlayModel: ActivityOverlayModel = ActivityOverlayModel(),
        overlayPresenter: any ActivityOverlayPresenting = NoOpActivityOverlayPresenter(),
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelDownloaders: [String: any SpeechModelDownloading] = [:],
        ttsRegistry: [String: any TextToSpeechBackend] = [:],
        ttsModelDownloaders: [String: any SpeechModelDownloading] = [:]
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
        self.diagnostics = diagnostics
        self.overlayModel = overlayModel
        self.overlayPresenter = overlayPresenter
        self.sttRegistry = sttRegistry
        self.speechModelDownloaders = speechModelDownloaders
        self.ttsRegistry = ttsRegistry
        self.ttsModelDownloaders = ttsModelDownloaders
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        self.settings = settings
        let state = SettingsState(settings)
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
        settingsState: SettingsState,
        permissionService: any GlobalPermissionAuthorizing,
        diagnostics: DiagnosticsRecorder,
        dictationCoordinator: (any DictationCoordinating)?,
        microphonePermissions: any MicrophonePermissionStatusProviding,
        privacySettingsOpener: any PrivacySettingsOpening,
        overlayModel: ActivityOverlayModel,
        overlayPresenter: any ActivityOverlayPresenting,
        sttRegistry: [String: any SpeechToTextBackend],
        speechModelDownloaders: [String: any SpeechModelDownloading],
        ttsRegistry: [String: any TextToSpeechBackend],
        ttsModelDownloaders: [String: any SpeechModelDownloading]
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
        self.diagnostics = diagnostics
        self.overlayModel = overlayModel
        self.overlayPresenter = overlayPresenter
        self.sttRegistry = sttRegistry
        self.speechModelDownloaders = speechModelDownloaders
        self.ttsRegistry = ttsRegistry
        self.ttsModelDownloaders = ttsModelDownloaders
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
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

    private func bindOverlayPresenter() {
        overlayModel.setStateHandler { [weak self] state in
            guard let self else { return }
            overlayPresenter.update(state: state, style: settingsState.value.activityOverlayStyle)
        }
    }

    private func updateSettings(_ update: (inout AppSettings) -> Void) {
        update(&settings)
        settingsState.value = settings
        registerHotkeys()
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

    func recheckDiagnostics() {
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        diagnostics.record(.permissionRechecked)
        registerHotkeys()
        Task { [weak self] in await self?.refreshSpeechBackendStatuses() }
    }

    func clearDiagnostics() { diagnostics.clear() }
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
            updateSettings { $0.autoReadEnabled.toggle() }
            statusText = settings.autoReadEnabled ? "Auto-read enabled" : "Auto-read disabled"
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
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
            statusText = "Speaking selected text"
        } catch {
            diagnostics.record(error is SelectionReadingError ? .selectionUnavailable : .ttsFailed)
            statusText = error.localizedDescription
        }
    }

    private func replayLast() async {
        do {
            try await speechCoordinator.replayLast()
            diagnostics.record(.ttsReplayed)
            statusText = "Replaying last speech"
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
            statusText = "Speaking test voice"
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
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
