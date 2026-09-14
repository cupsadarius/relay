import Observation

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

    @ObservationIgnored private let settingsStore: any SettingsStoring
    @ObservationIgnored private let selectionReader: any SelectionReading
    @ObservationIgnored private let preprocessor: RulesSpeechPreprocessor
    @ObservationIgnored private let speechCoordinator: any SpeechCoordinating
    @ObservationIgnored private let hotkeyManager: any HotkeyManaging
    @ObservationIgnored private let settingsState: SettingsState

    convenience init() {
        let settingsStore = SettingsStore()
        let settings = settingsStore.load()
        let state = SettingsState(settings)
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
            hotkeyManager: GlobalHotkeyManager(),
            loadedSettings: settings,
            settingsState: state
        )
    }

    init(
        settingsStore: any SettingsStoring,
        selectionReader: any SelectionReading,
        preprocessor: RulesSpeechPreprocessor,
        speechCoordinator: any SpeechCoordinating,
        hotkeyManager: any HotkeyManaging
    ) {
        let settings = settingsStore.load()
        self.settingsStore = settingsStore
        self.selectionReader = selectionReader
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.hotkeyManager = hotkeyManager
        self.settings = settings
        let state = SettingsState(settings)
        settingsState = state
        registerHotkeys()
    }

    private init(
        settingsStore: any SettingsStoring,
        selectionReader: any SelectionReading,
        preprocessor: RulesSpeechPreprocessor,
        speechCoordinator: any SpeechCoordinating,
        hotkeyManager: any HotkeyManaging,
        loadedSettings: AppSettings,
        settingsState: SettingsState
    ) {
        self.settingsStore = settingsStore
        self.selectionReader = selectionReader
        self.preprocessor = preprocessor
        self.speechCoordinator = speechCoordinator
        self.hotkeyManager = hotkeyManager
        settings = loadedSettings
        self.settingsState = settingsState
        registerHotkeys()
    }

    func setHotkey(_ definition: HotkeyDefinition, for action: HotkeyAction) {
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
        if case let .unavailable(message) = status {
            statusText = message
        }
    }

    private func handleHotkey(_ action: HotkeyAction, phase: HotkeyPhase) {
        if action == .dictate {
            dictationPhase = phase
            return
        }
        guard phase == .pressed else { return }

        switch action {
        case .dictate:
            break
        case .readSelection:
            Task { await readSelection() }
        case .stopSpeech:
            speechCoordinator.stop()
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
            let text = try selectionReader.readSelection()
            let prepared = preprocessor.prepare(text: text, mode: .userRequested)
            let request = SpeechRequest(
                text: prepared,
                source: .selection,
                mode: .userRequested,
                sessionID: nil
            )
            try await speechCoordinator.speak(request)
            statusText = "Speaking selected text"
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func replayLast() async {
        do {
            try await speechCoordinator.replayLast()
            statusText = "Replaying last speech"
        } catch {
            statusText = error.localizedDescription
        }
    }
}
