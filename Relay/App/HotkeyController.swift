import Foundation
import Observation

/// Global hotkey wiring: pushes definitions to the manager, dispatches matched actions, and
/// serializes dictation start/finish so a release never overtakes a slow start.
@MainActor
@Observable
final class HotkeyController {
    private(set) var dictationPhase: HotkeyPhase?
    private(set) var eventTapStatus: HotkeyRegistrationStatus = .unavailable("Not checked")

    @ObservationIgnored private let manager: any HotkeyManaging
    @ObservationIgnored private let settings: SettingsController
    @ObservationIgnored private let dictation: (any DictationCoordinating)?
    @ObservationIgnored private let speechActions: SpeechActions
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    /// The in-flight Read Selection / Replay Last action. Each new press of either hotkey, and
    /// Stop Speech, cancels it, so two quick presses can never both reach the speech coordinator.
    @ObservationIgnored private var speechActionTask: Task<Void, Never>?

    init(runtime: RelayRuntime, speechActions: SpeechActions) {
        manager = runtime.hotkeyManager
        settings = runtime.settingsController
        dictation = runtime.speechIn.dictationCoordinator
        self.speechActions = speechActions
        diagnostics = runtime.diagnostics
        statusSink = runtime.status
        manager.setHandler { [weak self] action, phase in
            self?.handle(action, phase: phase)
        }
    }

    deinit {
        dictationTask?.cancel()
        speechActionTask?.cancel()
    }

    func start() {
        manager.update(definitions: settings.current.hotkeys)
        ensureTap()
    }

    /// Called by `SettingsController.onHotkeysChanged`. Also retries the event tap: editing a
    /// hotkey is a natural moment to recover from an earlier "unavailable" status (e.g. the user
    /// just granted Accessibility and came back to Settings to fix a binding), and re-posts the
    /// unavailable status again if it's still not available, exactly as `ensureTap()` always does.
    func definitionsChanged(_ definitions: [HotkeyAction: HotkeyDefinition]) {
        manager.update(definitions: definitions)
        ensureTap()
    }

    /// Retries the event tap (e.g. after Accessibility is granted) without touching the matcher.
    func ensureTap() {
        let status = manager.ensureTap()
        eventTapStatus = status
        if case let .unavailable(message) = status {
            statusSink.post(message)
        }
    }

    private func handle(_ action: HotkeyAction, phase: HotkeyPhase) {
        if action == .dictate {
            diagnostics.record(.actionDispatched(action: action, phase: phase))
            dictationPhase = phase
            guard dictation != nil else { return }
            switch settings.current.dictationMode {
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
            runSpeechAction { await $0.readSelection() }
        case .stopSpeech:
            speechActionTask?.cancel()
            speechActionTask = nil
            speechActions.stopSpeech()
        case .replayLast:
            runSpeechAction { await $0.replayLast() }
        case .toggleAutoRead:
            settings.toggleAutoRead()
        }
    }

    /// Replaces any in-flight speech action. The cancelled one re-checks `Task.isCancelled`
    /// before speaking (inside `SpeechActions`), so it never reaches the speech coordinator.
    private func runSpeechAction(_ operation: @escaping @MainActor (SpeechActions) async -> Void) {
        speechActionTask?.cancel()
        let actions = speechActions
        speechActionTask = Task {
            guard !Task.isCancelled else { return }
            await operation(actions)
        }
    }

    private func enqueueDictation(_ operation: @escaping @MainActor (any DictationCoordinating) async -> Void) {
        let previous = dictationTask
        let coordinator = dictation
        dictationTask = Task { @MainActor in
            await previous?.value
            guard let coordinator else { return }
            await operation(coordinator)
        }
    }
}
