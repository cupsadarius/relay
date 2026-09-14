import Observation
@preconcurrency import AppKit

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
    private(set) var settings: AppSettings
    private(set) var dictationPhase: HotkeyPhase?
    private(set) var hotkeyConflictMessage: String?
    private(set) var permissionSnapshot: PermissionSnapshot
    private(set) var eventTapStatus: HotkeyRegistrationStatus = .unavailable("Not checked")
    var diagnosticsEntries: [DiagnosticEntry] { diagnostics.entries.reversed() }
    var diagnosticsCounters: DiagnosticsCounters { diagnostics.counters }

    @ObservationIgnored private let settingsStore: any SettingsStoring
    @ObservationIgnored private let selectionReader: any SelectionReading
    @ObservationIgnored private let preprocessor: RulesSpeechPreprocessor
    @ObservationIgnored private let speechCoordinator: any SpeechCoordinating
    @ObservationIgnored private let hotkeyManager: any HotkeyManaging
    @ObservationIgnored private let settingsState: SettingsState
    @ObservationIgnored private let permissionService: any GlobalPermissionAuthorizing
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    convenience init() {
        let settingsStore = SettingsStore()
        let settings = settingsStore.load()
        let state = SettingsState(settings)
        let diagnostics = DiagnosticsRecorder()
        let appleTTS = AppleTTSBackend()
        let router = TTSRouter(
            backends: [appleTTS.id: appleTTS],
            backendOrder: { state.value.ttsBackendOrder }
        )
        let coordinator = SpeechCoordinator(
            router: router,
            options: {
                TTSOptions(
                    voiceIdentifier: state.value.ttsVoiceIdentifier,
                    rate: state.value.ttsRate
                )
            }
        )
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
            diagnostics: diagnostics
        )
    }

    init(
        settingsStore: any SettingsStoring,
        selectionReader: any SelectionReading,
        preprocessor: RulesSpeechPreprocessor,
        speechCoordinator: any SpeechCoordinating,
        hotkeyManager: any HotkeyManaging,
        permissionService: any GlobalPermissionAuthorizing = PermissionService(),
        diagnostics: DiagnosticsRecorder = DiagnosticsRecorder()
    ) {
        let settings = settingsStore.load()
        self.settingsStore = settingsStore
        self.selectionReader = selectionReader
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.hotkeyManager = hotkeyManager
        self.permissionService = permissionService
        self.diagnostics = diagnostics
        activationObserver = nil
        permissionSnapshot = permissionService.snapshot()
        self.settings = settings
        let state = SettingsState(settings)
        settingsState = state
        registerHotkeys()
        observeAppActivation()
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
        diagnostics: DiagnosticsRecorder
    ) {
        self.settingsStore = settingsStore
        self.selectionReader = selectionReader
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.hotkeyManager = hotkeyManager
        self.permissionService = permissionService
        self.diagnostics = diagnostics
        activationObserver = nil
        permissionSnapshot = permissionService.snapshot()
        settings = loadedSettings
        self.settingsState = settingsState
        registerHotkeys()
        observeAppActivation()
    }

    func setHotkey(_ definition: HotkeyDefinition, for action: HotkeyAction) {
        if let conflictingAction = HotkeyAction.allCases.first(where: {
            $0 != action && settings.hotkeys[$0] == definition
        }) {
            let message = "\(action.title) conflicts with \(conflictingAction.title). Choose a different shortcut."
            hotkeyConflictMessage = message
            statusText = message
            return
        }
        hotkeyConflictMessage = nil
        updateSettings { $0.hotkeys[action] = definition }
    }

    func setDictationMode(_ mode: DictationMode) {
        updateSettings { $0.dictationMode = mode }
    }

    func setVoiceIdentifier(_ identifier: String?) {
        updateSettings { $0.ttsVoiceIdentifier = identifier }
    }

    func setSpeechRate(_ rate: Float) {
        updateSettings { $0.ttsRate = rate }
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
    }

    func recheckDiagnostics() {
        permissionSnapshot = permissionService.snapshot()
        diagnostics.record(.permissionRechecked)
        registerHotkeys()
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

    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

    private func handleHotkey(_ action: HotkeyAction, phase: HotkeyPhase) {
        if action == .dictate {
            diagnostics.record(.actionDispatched(action: action, phase: phase))
            dictationPhase = phase
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
